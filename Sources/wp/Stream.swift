import ArgumentParser
import CoreGraphics
import Foundation

// render a metal module as an animation. three outputs, chosen by --out:
//   a directory        numbered png frames
//   something.mp4      h264 through ffmpeg (needs ffmpeg on the path)
//   nothing            raw frames on stdout, --format gray8 or bgra8, for piping into a display driver
struct StreamCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "stream", abstract: "render a module as an animation: png frames, an mp4, or raw frames on stdout")

  @Argument(help: "metal module name (see `wp modules`)") var module: String
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
    let m = try Module.named(module)
    guard m.host == .metal else { throw ValidationError("only metal modules animate; \(m.name) is \(m.host.rawValue)") }
    let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { throw ValidationError("--size must look like 800x480") }
    let (w, h) = (parts[0], parts[1])
    guard fps > 0 else { throw ValidationError("--fps must be positive") }
    let seed = seed ?? UInt32.random(in: 0..<16_000_000)
    let source = try String(contentsOf: m.entryURL, encoding: .utf8)
    let renderer = try MetalRenderer(source: source, width: w, height: h, params: set)
    let total = seconds > 0 ? Int((seconds * fps).rounded()) : Int.max
    let stderr = FileHandle.standardError

    var sink: Sink
    if let out {
      if out.lowercased().hasSuffix(".mp4") {
        sink = try FFmpegSink(path: (out as NSString).expandingTildeInPath, width: w, height: h, fps: fps)
      } else {
        sink = PNGSink(dir: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), width: w, height: h)
      }
    } else {
      guard seconds > 0 || !FileHandle.standardOutput.isTerminal else { throw ValidationError("raw frames on a terminal? give --out or redirect") }
      switch format {
      case "gray8": sink = RawSink(gray: true)
      case "bgra8": sink = RawSink(gray: false)
      default: throw ValidationError("--format is gray8 or bgra8")
      }
    }
    if verbose { stderr.write("\(m.name) seed=\(seed) \(w)x\(h) @\(fps)fps -> \(out ?? "stdout \(format)")\n".data(using: .utf8)!) }

    let started = Date()
    var i = 0
    while i < total {
      let t = Float(start + Double(i) / fps)
      let bytes = try renderer.frame(seed: seed, time: t)
      try sink.write(bytes, index: i, renderer: renderer)
      i += 1
      if verbose && i % Int(max(fps, 1)) == 0 {
        let el = Date().timeIntervalSince(started)
        stderr.write("  \(i) frames, \(String(format: "%.1f", Double(i) / el)) fps\n".data(using: .utf8)!)
      }
    }
    try sink.finish()
  }
}

private protocol Sink {
  mutating func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws
  func finish() throws
}

private struct PNGSink: Sink {
  let dir: URL, width: Int, height: Int
  func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
    var bytes = bgra
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
          let img = ctx.makeImage() else { throw WPError("couldn't build CGImage") }
    try MetalHost.writePNG(img, to: dir.appendingPathComponent(String(format: "%05d.png", index)))
  }
  func finish() throws {}
}

private struct RawSink: Sink {
  let gray: Bool
  func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
    if gray {
      var g = [UInt8](repeating: 0, count: bgra.count / 4)
      for p in 0..<g.count {
        let b = Int(bgra[p * 4]), gg = Int(bgra[p * 4 + 1]), r = Int(bgra[p * 4 + 2])
        g[p] = UInt8((r * 299 + gg * 587 + b * 114) / 1000)   // rec.601 luma
      }
      FileHandle.standardOutput.write(Data(g))
    } else {
      FileHandle.standardOutput.write(Data(bgra))
    }
  }
  func finish() throws {}
}

private final class FFmpegSink: Sink {
  let process = Process()
  let input: Pipe
  init(path: String, width: Int, height: Int, fps: Double) throws {
    guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw WPError("ffmpeg not found (brew install ffmpeg)")
    }
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", "\(fps)",
                         "-i", "-", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",   // h264 wants even dimensions
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", path]
    input = Pipe()
    process.standardInput = input
    try process.run()
  }
  func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
    input.fileHandleForWriting.write(Data(bgra))
  }
  func finish() throws {
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw WPError("ffmpeg exited \(process.terminationStatus)") }
  }
}

private extension FileHandle {
  var isTerminal: Bool { isatty(fileDescriptor) != 0 }
}
