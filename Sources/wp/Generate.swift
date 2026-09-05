import AppKit
import ArgumentParser

enum Generator {
  static func generate(_ m: Module, width: Int, height: Int, seed: UInt32, params: [String], to out: URL, verbose: Bool) throws {
    switch m.host {
    case .metal:
      let source = try String(contentsOf: m.entryURL, encoding: .utf8)
      let img = try MetalHost.render(source: source, width: width, height: height, seed: seed)
      try MetalHost.writePNG(img, to: out)
    case .web:
      try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      try WebHost.render(module: m, width: width, height: height, seed: seed, params: params, to: out, verbose: verbose)
    case .exec:
      try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      var args = ["--width", "\(width)", "--height", "\(height)", "--seed", "\(seed)", "--out", out.path]
      for p in params { args += ["--param", p] }
      let r = try Subprocess.run(executable: m.entryURL.path, arguments: args, cwd: m.dir)
      if verbose || r.status != 0 { FileHandle.standardError.write((r.stdout + r.stderr).data(using: .utf8)!) }
      if r.status != 0 { throw WPError("\(m.name) exited \(r.status)") }
    }
    guard FileManager.default.fileExists(atPath: out.path) else {
      throw WPError("\(m.name) finished but didn't write \(out.path)")
    }
  }
}

struct ModulesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "modules", abstract: "list generator modules")

  func run() throws {
    for m in try Module.discover() {
      print("\(m.name)  [\(m.host.rawValue)]  \(m.description)")
    }
  }
}

struct GenCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "gen", abstract: "generate a wallpaper from a module and set it")

  @Argument(help: "module name (see `wp modules`)") var module: String
  @Option(name: .shortAndLong, help: "seed; random if omitted") var seed: UInt32?
  @Option(name: .shortAndLong, help: "display index, name substring, or 'all'") var display: String?
  @Option(name: .long, help: "render at WxH instead of a display's size (implies --no-set)") var size: String?
  @Option(name: .shortAndLong, help: "write here instead of the generated dir") var out: String?
  @Option(name: .long, parsing: .upToNextOption, help: "module parameter, k=v (repeatable)") var set: [String] = []
  @Flag(name: .long, help: "write the file but don't set it as wallpaper") var noSet = false
  @Flag(name: .shortAndLong, help: "show host/module logs") var verbose = false

  func run() throws {
    let m = try Module.named(module)
    let cfg = try Root.config()
    let seed = seed ?? UInt32.random(in: 0..<16_000_000)

    var targets: [(w: Int, h: Int, screen: Screen?)]
    if let size {
      let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
      guard parts.count == 2 else { throw ValidationError("--size must look like 3840x1600") }
      targets = [(parts[0], parts[1], nil)]
    } else {
      targets = try Screen.select(display).map { ($0.pixelSize.w, $0.pixelSize.h, $0) }
    }
    if out != nil && targets.count > 1 {
      throw ValidationError("--out only works with a single target (use --display N or --size)")
    }

    var index = out == nil ? try Index.load() : nil
    for t in targets {
      let start = Date()
      let url = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? cfg.generatedURL.appendingPathComponent("\(m.name)-\(seed)-\(t.w)x\(t.h).png")
      try Generator.generate(m, width: t.w, height: t.h, seed: seed, params: set, to: url, verbose: verbose)
      let ms = Int(Date().timeIntervalSince(start) * 1000)
      print("\(url.path)  seed=\(seed)  \(ms)ms")
      index?.add(generated: url, module: m, seed: seed, width: t.w, height: t.h)
      if let s = t.screen, !noSet {
        try NSWorkspace.shared.setDesktopImageURL(url, for: s.nsScreen, options: Fill.crop.options)
        index?.markShown(url.standardizedFileURL.path)
        print("  -> \(s.index) \(s.name)")
      }
    }
    try index?.save()
  }
}
