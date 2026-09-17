import Foundation

public enum Generator {
  public static func generate(_ module: Module, width: Int, height: Int, seed: UInt32, params: [String], to out: URL, verbose: Bool, time: Float = 0) async throws {
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
