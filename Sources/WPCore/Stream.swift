import CoreGraphics
import Foundation

public protocol Sink {
  mutating func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws
  func finish() throws
}

public struct PNGSink: Sink {
  public let directory: URL, width: Int, height: Int
  public init(directory: URL, width: Int, height: Int) { self.directory = directory; self.width = width; self.height = height }
  public func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
    var bytes = bgra
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
          let image = context.makeImage() else { throw WPError("couldn't build CGImage") }
    try MetalHost.writePNG(image, to: directory.appendingPathComponent(String(format: "%05d.png", index)))
  }
  public func finish() throws {}
}

public struct RawSink: Sink {
  public let gray: Bool
  public init(gray: Bool) { self.gray = gray }
  public func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
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
  public func finish() throws {}
}

public final class FFmpegSink: Sink {
  let process = Process()
  let input: Pipe
  public init(path: String, width: Int, height: Int, fps: Double) throws {
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
  public func write(_ bgra: [UInt8], index: Int, renderer: MetalRenderer) throws {
    input.fileHandleForWriting.write(Data(bgra))
  }
  public func finish() throws {
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw WPError("ffmpeg exited \(process.terminationStatus)") }
  }
}

public extension FileHandle {
  var isTerminal: Bool { isatty(fileDescriptor) != 0 }
}
