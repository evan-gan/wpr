import AppKit
import UniformTypeIdentifiers
import WebKit

// renders a web module in an offscreen WKWebView. the module folder is served over the wpr:// scheme
// (ES modules and importmaps don't work over file://), the page gets window.WP before any of its
// script runs, and we snapshot once it sets window.WP_DONE
enum WebHost {
  @MainActor
  static func render(module: Module, width: Int, height: Int, seed: UInt32, params: [String], verbose: Bool) async throws -> CGImage {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // a module is self-contained: its own folder is everything the page can load
    let root = module.directory.resolvingSymlinksInPath()
    let page = module.manifest.entry

    var parameters: [String: String] = [:]
    for parameter in params {
      guard let equals = parameter.firstIndex(of: "=") else { throw WPError("bad --set '\(parameter)', want name=value") }
      parameters[String(parameter[..<equals])] = String(parameter[parameter.index(after: equals)...])
    }
    let wp = try JSONSerialization.data(withJSONObject: ["width": width, "height": height, "seed": Int(seed), "params": parameters])

    let relay = Relay(verbose: verbose)
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(ModuleScheme(root: root), forURLScheme: "wpr")
    configuration.userContentController.add(relay, name: "wpr")
    configuration.userContentController.addUserScript(WKUserScript(
      source: "window.WP = \(String(decoding: wp, as: UTF8.self));\n" + pageScript,
      injectionTime: .atDocumentStart, forMainFrameOnly: true))

    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let webView = WKWebView(frame: frame, configuration: configuration)
    webView.navigationDelegate = relay
    // css pixels == device pixels, whatever screen the window lands on. WebKit SPI; if it ever
    // disappears the size check on the snapshot fails loudly instead of shipping a blurry image
    let override = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
    if webView.responds(to: override) {
      typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
      unsafeBitCast(webView.method(for: override), to: Setter.self)(webView, override, 1.0)
    }

    // a window to draw in, kept off every screen so nothing flashes
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = webView
    window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
    window.orderBack(nil)
    defer { window.orderOut(nil) }

    let started = Date()
    webView.load(URLRequest(url: URL(string: "wpr://module/\(page)")!))
    let finished = await relay.waitForDone(timeoutMs: module.timeoutMs ?? 20000)
    if let failure = relay.failure { throw WPError("page failed to load: \(failure)") }
    if !finished { FileHandle.standardError.write(Data("[host] no WP_DONE after \(module.timeoutMs ?? 20000)ms, snapshotting anyway\n".utf8)) }
    if verbose { FileHandle.standardError.write(Data("[host] page ready in \(Int(Date().timeIntervalSince(started) * 1000))ms\n".utf8)) }

    let snapshot = WKSnapshotConfiguration()
    snapshot.rect = frame
    snapshot.snapshotWidth = NSNumber(value: width)
    let image = try await webView.takeSnapshot(configuration: snapshot)
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw WPError("snapshot returned no image") }
    guard cgImage.width == width, cgImage.height == height else {
      throw WPError("snapshot is \(cgImage.width)x\(cgImage.height), wanted \(width)x\(height)")
    }
    return cgImage
  }

  // WP_DONE becomes a message to us, and console output and page errors come along for --verbose
  static let pageScript = """
  (function () {
    const send = (kind, args) => { try { window.webkit.messageHandlers.wpr.postMessage(kind + " " + args.map(a => a instanceof Error ? (a.stack || a.message) : String(a)).join(" ")); } catch (e) {} };
    let done = false;
    Object.defineProperty(window, "WP_DONE", { get: () => done, set: (v) => { done = !!v; if (done) send("done", []); } });
    for (const level of ["log", "warn", "error"]) { const original = console[level].bind(console); console[level] = (...args) => { send(level, args); original(...args); }; }
    window.addEventListener("error", e => send("error", [e.message + " (" + e.filename + ":" + e.lineno + ")"]));
    window.addEventListener("unhandledrejection", e => send("error", [e.reason]));
  })();
  """

  final class Relay: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let verbose: Bool
    private(set) var failure: String?
    private var continuation: CheckedContinuation<Bool, Never>?
    init(verbose: Bool) { self.verbose = verbose }

    func waitForDone(timeoutMs: Int) async -> Bool {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(timeoutMs))
          self.finish(done: false)
        }
      }
    }

    private func finish(done: Bool) {
      continuation?.resume(returning: done)
      continuation = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      let text = "\(message.body)"
      if text == "done " { finish(done: true); return }
      if verbose || text.hasPrefix("error") { FileHandle.standardError.write(Data("[page] \(text)\n".utf8)) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error.localizedDescription; finish(done: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error.localizedDescription; finish(done: false) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = "web content process crashed"; finish(done: false) }
  }

  // wpr://module/<path> serves <module folder>/<path>
  final class ModuleScheme: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
      guard let url = task.request.url else { return }
      let file = root.appending(path: url.path.removingPercentEncoding ?? url.path).standardizedFileURL
      guard file.path.hasPrefix(root.path + "/"), let data = FileManager.default.contents(atPath: file.path) else {
        task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        task.didFinish()
        return
      }
      let headers = ["Content-Type": contentType(file.pathExtension), "Content-Length": "\(data.count)"]
      task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
      task.didReceive(data)
      task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    func contentType(_ pathExtension: String) -> String {
      UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
  }
}
