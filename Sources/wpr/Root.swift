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
  var rotation = Rotation()
  var pool = Pool()

  var libraryURL: URL { URL(fileURLWithPath: (library as NSString).expandingTildeInPath) }
  var generatedURL: URL { URL(fileURLWithPath: (generated as NSString).expandingTildeInPath) }

  struct Sources: Decodable {
    var enabled: [String]
  }

  // every key optional so an older config.toml keeps working when new knobs appear
  struct Rotation: Decodable {
    var minFit = 0.6
    var minRes = 0.3
    var matchAppearance = true
    var interval = "30m"
    var holdManual = "2h"

    init() {}
    private enum K: String, CodingKey {
      case minFit = "min_fit", minRes = "min_res", matchAppearance = "match_appearance", interval, holdManual = "hold_manual"
    }
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: K.self)
      minFit = try container.decodeIfPresent(Double.self, forKey: .minFit) ?? minFit
      minRes = try container.decodeIfPresent(Double.self, forKey: .minRes) ?? minRes
      matchAppearance = try container.decodeIfPresent(Bool.self, forKey: .matchAppearance) ?? matchAppearance
      interval = try container.decodeIfPresent(String.self, forKey: .interval) ?? interval
      holdManual = try container.decodeIfPresent(String.self, forKey: .holdManual) ?? holdManual
    }

    var holdManualSeconds: TimeInterval {
      TimeInterval((try? TimerCommand.parseDuration(holdManual)) ?? 7200)
    }
  }

  struct Pool: Decodable {
    var perModule = 4
    var keep = 12

    init() {}
    private enum K: String, CodingKey { case perModule = "per_module", keep }
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: K.self)
      perModule = try container.decodeIfPresent(Int.self, forKey: .perModule) ?? perModule
      keep = try container.decodeIfPresent(Int.self, forKey: .keep) ?? keep
    }
  }

  private enum K: String, CodingKey { case library, generated, sources, rotation, pool }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: K.self)
    library = try container.decode(String.self, forKey: .library)
    generated = try container.decodeIfPresent(String.self, forKey: .generated) ?? Root.dataDirectory.appending(path: "generated").path
    sources = try container.decodeIfPresent(Sources.self, forKey: .sources) ?? Sources(enabled: [])
    rotation = try container.decodeIfPresent(Rotation.self, forKey: .rotation) ?? Rotation()
    pool = try container.decodeIfPresent(Pool.self, forKey: .pool) ?? Pool()
  }
}

enum Root {
  private static var cached: URL?

  static func url() throws -> URL {
    if let cached { return cached }
    let found = try resolve()
    cached = found
    return found
  }

  static var configURL: URL { URL.homeDirectory.appending(path: ".config/wpr/config.toml") }
  /// the index, thumbnails, and generated wallpapers
  static var dataDirectory: URL { URL.applicationSupportDirectory.appending(path: "wpr") }
  static func modulesDir() throws -> URL { try url().appendingPathComponent("modules") }

  // first run copies config.default.toml into place so there's something to edit
  static func config() throws -> Config {
    let file = configURL
    if !FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: try url().appendingPathComponent("config.default.toml"), to: file)
      FileHandle.standardError.write("wpr: created \(file.path) — set `library` to your wallpapers folder\n".data(using: .utf8)!)
    }
    let text = try String(contentsOf: file, encoding: .utf8)
    return try TOMLDecoder().decode(Config.self, from: text)
  }

  private static func isRoot(_ directory: URL) -> Bool {
    let fileManager = FileManager.default
    return fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path)
      && fileManager.fileExists(atPath: directory.appendingPathComponent("modules").path)
  }

  private static func resolve() throws -> URL {
    let fileManager = FileManager.default
    if let override = ProcessInfo.processInfo.environment["WP_ROOT"] {
      return URL(fileURLWithPath: override)
    }
    var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    while true {
      if isRoot(directory) { return directory }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    let pointer = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".config/wp/root")
    if let text = try? String(contentsOf: pointer, encoding: .utf8) {
      let url = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
      if isRoot(url) { return url }
    }
    throw WPError("can't find the wp repo root. set WP_ROOT, run from inside the repo, or `make install`")
  }
}
