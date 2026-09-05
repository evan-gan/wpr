import Foundation
import TOMLKit

struct WPError: LocalizedError, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
  var errorDescription: String? { description }
}

struct Config: Decodable {
  var library: String
  var generated: String
  var sources: Sources
  var rotation: Rotation
  var pool: Pool

  struct Sources: Decodable {
    var enabled: [String]
  }

  struct Rotation: Decodable {
    var minFit: Double
    var minRes: Double
    var interval: String
    private enum CodingKeys: String, CodingKey { case minFit = "min_fit", minRes = "min_res", interval }
  }

  struct Pool: Decodable {
    var perModule: Int
    var keep: Int
    private enum CodingKeys: String, CodingKey { case perModule = "per_module", keep }
  }

  var libraryURL: URL { URL(fileURLWithPath: (library as NSString).expandingTildeInPath) }
  var generatedURL: URL { URL(fileURLWithPath: (generated as NSString).expandingTildeInPath) }
}

enum Root {
  private static var cached: URL?

  static func url() throws -> URL {
    if let cached { return cached }
    let found = try resolve()
    cached = found
    return found
  }

  static func config() throws -> Config {
    let text = try String(contentsOf: try url().appendingPathComponent("config.toml"), encoding: .utf8)
    return try TOMLDecoder().decode(Config.self, from: text)
  }

  static func modulesDir() throws -> URL { try url().appendingPathComponent("modules") }

  private static func resolve() throws -> URL {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["WP_ROOT"] {
      return URL(fileURLWithPath: env)
    }
    var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
    while true {
      if fm.fileExists(atPath: dir.appendingPathComponent("config.toml").path),
         fm.fileExists(atPath: dir.appendingPathComponent("modules").path) {
        return dir
      }
      let parent = dir.deletingLastPathComponent()
      if parent.path == dir.path { break }
      dir = parent
    }
    let pointer = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/wp/root")
    if let s = try? String(contentsOf: pointer, encoding: .utf8) {
      return URL(fileURLWithPath: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    throw WPError("can't find the wp repo root. set WP_ROOT, run from inside the repo, or `make install`")
  }
}
