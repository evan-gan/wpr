import AppKit
import ArgumentParser
import WPCore

struct ModulesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "modules", abstract: "list generator modules")

  func run() throws {
    for module in try Module.discover() {
      print("\(module.fullName.pad(28)) \(module.host.rawValue.pad(6)) \(module.description)")
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
  @OptionGroup var spaces: SpacesOption

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
    var applied: [String: URL] = [:]
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
        applied[screen.uuid] = url
        index?.markShown(url.standardizedFileURL.path)
        index?.markManual(screen)
        print("  -> \(screen.index) \(screen.name)")
      }
    }
    try index?.save()
    try spaces.spread(applied, configuration: configuration)
  }
}

// render a metal module as an animation. three outputs, chosen by --out:
//   a directory        numbered png frames
//   something.mp4      h264 through ffmpeg (needs ffmpeg on the path)
//   nothing            raw frames on stdout, --format gray8 or bgra8, for piping into a display driver
struct StreamCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "stream", abstract: "render a module as an animation: png frames, an mp4, or raw frames on stdout")

  @Argument(help: "metal module name (see `wpr modules`)") var module: String
  @Option(name: .shortAndLong, help: "seed; random if omitted") var seed: UInt32?
  @Option(name: .long, help: "frame size, WxH") var size: String
  @Option(name: .long, help: "frames per second") var fps: Double = 12
  @Option(name: .long, help: "length in seconds; 0 runs until killed (stdout only)") var seconds: Double = 10
  @Option(name: .long, help: "start time in seconds") var start: Double = 0
  @Option(name: .shortAndLong, help: "png directory, .mp4 file, or omit for raw frames on stdout") var out: String?
  @Option(name: .long, help: "raw frame format on stdout: gray8 or bgra8") var format: String = "gray8"
  @Option(name: .long, parsing: .upToNextOption, help: "module parameter, k=v (repeatable)") var set: [String] = []
  @Flag(name: .shortAndLong, help: "progress on stderr") var verbose = false

  func run() throws {
    let selectedModule = try Module.named(module)
    guard selectedModule.host == .metal else { throw ValidationError("only metal modules animate; \(selectedModule.name) is \(selectedModule.host.rawValue)") }
    let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { throw ValidationError("--size must look like 800x480") }
    let (width, height) = (parts[0], parts[1])
    guard fps > 0 else { throw ValidationError("--fps must be positive") }
    let seed = seed ?? UInt32.random(in: 0..<16_000_000)
    let source = try String(contentsOf: selectedModule.entryURL, encoding: .utf8)
    let renderer = try MetalRenderer(source: source, width: width, height: height, params: set)
    let total = seconds > 0 ? Int((seconds * fps).rounded()) : Int.max
    let stderr = FileHandle.standardError

    var sink: Sink
    if let out {
      if out.lowercased().hasSuffix(".mp4") {
        sink = try FFmpegSink(path: (out as NSString).expandingTildeInPath, width: width, height: height, fps: fps)
      } else {
        sink = PNGSink(directory: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), width: width, height: height)
      }
    } else {
      guard seconds > 0 || !FileHandle.standardOutput.isTerminal else { throw ValidationError("raw frames on a terminal? give --out or redirect") }
      switch format {
      case "gray8": sink = RawSink(gray: true)
      case "bgra8": sink = RawSink(gray: false)
      default: throw ValidationError("--format is gray8 or bgra8")
      }
    }
    if verbose { stderr.write("\(selectedModule.name) seed=\(seed) \(width)x\(height) @\(fps)fps -> \(out ?? "stdout \(format)")\n".data(using: .utf8)!) }

    let started = Date()
    var frameIndex = 0
    while frameIndex < total {
      let time = Float(start + Double(frameIndex) / fps)
      let bytes = try renderer.frame(seed: seed, time: time)
      try sink.write(bytes, index: frameIndex, renderer: renderer)
      frameIndex += 1
      if verbose && frameIndex % Int(max(fps, 1)) == 0 {
        let elapsed = Date().timeIntervalSince(started)
        stderr.write("  \(frameIndex) frames, \(String(format: "%.1f", Double(frameIndex) / elapsed)) fps\n".data(using: .utf8)!)
      }
    }
    try sink.finish()
  }
}
