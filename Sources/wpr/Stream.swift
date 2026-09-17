import CoreGraphics
import Foundation
protocol Sink {
  mutating func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws
  func finish() throws
}

struct PNGSink: Sink {
  let directory: URL, width: Int, height: Int
  func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
    var bytes = bgra
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
          let image = context.makeImage() else { throw WPError("couldn't build CGImage") }
    try MetalHost.writePNG(image, to: directory.appendingPathComponent(String(format: "%05d.png", index)))
  }
  func finish() throws {}
}

struct RawSink: Sink {
  let gray: Bool
  func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
    if gray {
      var luma = [UInt8](repeating: 0, count: bgra.count / 4)
      for pixel in 0..<luma.count {
        let blue = Int(bgra[pixel * 4]), green = Int(bgra[pixel * 4 + 1]), red = Int(bgra[pixel * 4 + 2])
        luma[pixel] = UInt8((red * 299 + green * 587 + blue * 114) / 1000)   // rec.601
      }
      FileHandle.standardOutput.write(Data(luma))
    } else {
      FileHandle.standardOutput.write(Data(bgra))
    }
  }
  func finish() throws {}
}

final class FFmpegSink: Sink {
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

extension FileHandle {
  var isTerminal: Bool { isatty(fileDescriptor) != 0 }
}
