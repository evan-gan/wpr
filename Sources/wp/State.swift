import AppKit
import ArgumentParser
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum Thumbs {
  static var dir: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/wp/thumbs")
  }

  static func key(_ path: String) -> String {
    String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
  }

  // returns the thumb key once the 640px jpeg exists; nil if the image can't be decoded
  @discardableResult
  static func ensure(_ path: String) -> String? {
    let k = key(path)
    let out = dir.appendingPathComponent("\(k).jpg")
    if FileManager.default.fileExists(atPath: out.path) { return k }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 640,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, thumb, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    return CGImageDestinationFinalize(dst) ? k : nil
  }
}

struct State: Encodable {
  struct Display: Encodable {
    let index: Int, name: String, width: Int, height: Int, aspect: Double
    let wallpaper: String?, wallpaperThumb: String?
  }
  struct Source: Encodable {
    let name: String, kind: String, enabled: Bool, count: Int, description: String?
  }
  struct Fit: Encodable {
    let display: Int, fit: Double, res: Double, eligible: Bool
  }
  struct Item: Encodable {
    let path: String, name: String, source: String, kind: String
    let width: Int, height: Int, aspect: Double
    let module: String?, seed: UInt32?
    let lum: Double?, dominant: [String]
    let lastShown: Date?, shownCount: Int
    let thumb: String?
    let fits: [Fit]
  }
  struct Rules: Encodable { let minFit: Double, minRes: Double, matchAppearance: Bool }

  let power: String
  let dark: Bool
  let displays: [Display]
  let sources: [Source]
  let candidates: [Item]
  let rules: Rules
}

struct StateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "state", abstract: "everything the gallery needs, as one JSON document")

  func run() throws {
    let cfg = try Root.config()
    let index = try Index.load()
    let modules = try Module.discover()
    let screens = Screen.all

    let displays = screens.map { s in
      let wp = s.currentWallpaper?.standardizedFileURL.path
      return State.Display(index: s.index, name: s.name, width: s.pixelSize.w, height: s.pixelSize.h, aspect: s.aspect,
                           wallpaper: wp, wallpaperThumb: wp.flatMap(Thumbs.ensure))
    }

    let counts = Dictionary(grouping: index.candidates.values, by: \.source).mapValues(\.count)
    let sources = Set(counts.keys).union(modules.map(\.name)).sorted().map { n in
      let m = modules.first { $0.name == n }
      return State.Source(name: n, kind: m == nil ? "folder" : "module", enabled: cfg.sources.enabled.contains(n),
                          count: counts[n] ?? 0, description: m?.description)
    }

    let candidates = index.candidates.values.sorted { ($0.source, $0.name) < ($1.source, $1.name) }.map { c in
      let fits = screens.map { s in
        let f = Fit.score(imageAspect: c.aspect, displayAspect: s.aspect)
        let r = Fit.resolution(c, s)
        return State.Fit(display: s.index, fit: f, res: r,
                         eligible: Fit.sizeAllowed(c, s) && f >= cfg.rotation.minFit && r >= cfg.rotation.minRes)
      }
      return State.Item(path: c.path, name: c.name, source: c.source, kind: c.kind.rawValue,
                        width: c.width, height: c.height, aspect: c.aspect, module: c.module, seed: c.seed,
                        lum: c.palette?.luminance, dominant: c.palette?.dominant ?? [],
                        lastShown: c.lastShown, shownCount: c.shownCount, thumb: Thumbs.ensure(c.path), fits: fits)
    }

    let state = State(power: Power.isOnAC() ? "AC" : "battery", dark: Appearance.isDark, displays: displays,
                      sources: sources, candidates: candidates,
                      rules: .init(minFit: cfg.rotation.minFit, minRes: cfg.rotation.minRes, matchAppearance: cfg.rotation.matchAppearance))
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    print(String(decoding: try enc.encode(state), as: UTF8.self))
  }
}

struct UICommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ui", abstract: "open the gallery in your browser")

  @Option(name: .shortAndLong, help: "port for the local server") var port = 4747
  @Flag(name: .long, help: "don't open the browser") var noOpen = false

  func run() throws {
    let root = try Root.url()
    let wpBin = Bundle.main.executableURL?.standardizedFileURL.path ?? CommandLine.arguments[0]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: try WebHost.bunPath())
    p.arguments = [root.appendingPathComponent("hosts/ui/server.ts").path, "--port", "\(port)", "--wp", wpBin]
    var env = ProcessInfo.processInfo.environment
    env["WP_ROOT"] = root.path
    p.environment = env
    try p.run()
    Subprocess.forwardingSignals(to: p) {
      print("gallery at http://localhost:\(port)  (ctrl-c to stop)")
      if !noOpen {
        usleep(500_000)
        _ = try? Subprocess.run(executable: "/usr/bin/open", arguments: ["http://localhost:\(port)"])
      }
      p.waitUntilExit()
    }
  }
}
