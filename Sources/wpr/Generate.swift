import AppKit
import ArgumentParser

enum Generator {
  static func generate(_ module: Module, width: Int, height: Int, seed: UInt32, params: [String], to out: URL, verbose: Bool, time: Float = 0) async throws {
    switch module.host {
    case .metal:
      let source = try String(contentsOf: module.entryURL, encoding: .utf8)
      let image = try MetalHost.render(source: source, width: width, height: height, seed: seed, params: params, time: time)
      try MetalHost.writePNG(image, to: out)
    case .web:
      let image = try await WebHost.render(module: module, width: width, height: height, seed: seed, params: params, verbose: verbose)
      try MetalHost.writePNG(image, to: out)
    }
    guard FileManager.default.fileExists(atPath: out.path) else {
      throw WPError("\(module.name) finished but didn't write \(out.path)")
    }
  }
}

struct ModulesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "modules", abstract: "list generator modules")

  func run() throws {
    for module in try Module.discover() {
      print("\(module.name)  [\(module.host.rawValue)]  \(module.description)")
    }
  }
}

struct GenCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "gen", abstract: "generate a wallpaper from a module and set it")

  @Argument(help: "module name (see `wpr modules`)") var module: String
  @Option(name: .shortAndLong, help: "seed; random if omitted") var seed: UInt32?
  @Option(name: .shortAndLong, help: "display index, name substring, or 'all'") var display: String?
  @Option(name: .long, help: "render at WxH instead of a display's size (implies --no-set)") var size: String?
  @Option(name: .shortAndLong, help: "write here instead of the generated dir") var out: String?
  @Option(name: .long, parsing: .upToNextOption, help: "module parameter, k=v (repeatable)") var set: [String] = []
  @Option(name: .long, help: "animation time in seconds, for modules that move (metal only)") var time: Float = 0
  @Flag(name: .long, help: "write the file but don't set it as wallpaper") var noSet = false
  @Flag(name: .shortAndLong, help: "show host/module logs") var verbose = false

  func run() async throws {
    let selectedModule = try Module.named(module)
    let configuration = try Root.config()
    let seed = seed ?? UInt32.random(in: 0..<16_000_000)

    var targets: [(width: Int, height: Int, screen: Screen?)]
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
    for target in targets {
      let start = Date()
      let url = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? configuration.generatedURL.appendingPathComponent("\(selectedModule.name)-\(seed)-\(target.width)x\(target.height).png")
      try await Generator.generate(selectedModule, width: target.width, height: target.height, seed: seed, params: set, to: url, verbose: verbose, time: time)
      let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
      print("\(url.path)  seed=\(seed)  \(milliseconds)ms")
      index?.add(generated: url, module: selectedModule, seed: seed, width: target.width, height: target.height)
      if let screen = target.screen, !noSet {
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen.nsScreen, options: Fill.crop.options)
        index?.markShown(url.standardizedFileURL.path)
        index?.markManual(screen)
        print("  -> \(screen.index) \(screen.name)")
      }
    }
    try index?.save()
  }
}
