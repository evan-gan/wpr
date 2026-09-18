import Foundation
import TOMLKit

public struct WPError: LocalizedError, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
  public var errorDescription: String? { description }
}

public struct Config: Decodable {
  public var library: String
  public var generated: String
  public var sources: Sources
  public var rotation = Rotation()
  public var pool = Pool()

  public var libraryURL: URL { URL(fileURLWithPath: (library as NSString).expandingTildeInPath) }
  public var generatedURL: URL { URL(fileURLWithPath: (generated as NSString).expandingTildeInPath) }

  public struct Sources: Decodable {
    public var enabled: [String]
  }

  // every key optional so an older config.toml keeps working when new knobs appear
  public struct Rotation: Decodable {
    public var minFit = 0.6
    public var minRes = 0.3
    public var matchAppearance = true
    public var interval = "30m"
    public var holdManual = "2h"
    public var allSpaces = true

    init() {}
    private enum K: String, CodingKey {
      case minFit = "min_fit", minRes = "min_res", matchAppearance = "match_appearance", interval, holdManual = "hold_manual", allSpaces = "all_spaces"
    }
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: K.self)
      minFit = try container.decodeIfPresent(Double.self, forKey: .minFit) ?? minFit
      minRes = try container.decodeIfPresent(Double.self, forKey: .minRes) ?? minRes
      matchAppearance = try container.decodeIfPresent(Bool.self, forKey: .matchAppearance) ?? matchAppearance
      interval = try container.decodeIfPresent(String.self, forKey: .interval) ?? interval
      holdManual = try container.decodeIfPresent(String.self, forKey: .holdManual) ?? holdManual
      allSpaces = try container.decodeIfPresent(Bool.self, forKey: .allSpaces) ?? allSpaces
    }

    public var holdManualSeconds: TimeInterval {
      TimeInterval((try? Interval.parse(holdManual)) ?? 7200)
    }
  }

  public struct Pool: Decodable {
    public var perModule = 4
    public var keep = 12

    init() {}
    private enum K: String, CodingKey { case perModule = "per_module", keep }
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: K.self)
      perModule = try container.decodeIfPresent(Int.self, forKey: .perModule) ?? perModule
      keep = try container.decodeIfPresent(Int.self, forKey: .keep) ?? keep
    }
  }

  private enum K: String, CodingKey { case library, generated, sources, rotation, pool }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: K.self)
    library = try container.decode(String.self, forKey: .library)
    generated = try container.decodeIfPresent(String.self, forKey: .generated) ?? Root.dataDirectory.appending(path: "generated").path
    sources = try container.decodeIfPresent(Sources.self, forKey: .sources) ?? Sources(enabled: [])
    rotation = try container.decodeIfPresent(Rotation.self, forKey: .rotation) ?? Rotation()
    pool = try container.decodeIfPresent(Pool.self, forKey: .pool) ?? Pool()
  }
}

public enum Root {
  public static var configURL: URL { URL.homeDirectory.appending(path: ".config/wpr/config.toml") }
  /// the index, thumbnails, and generated wallpapers
  public static var dataDirectory: URL { URL.applicationSupportDirectory.appending(path: "wpr") }
  /// installed modules, as <host>/<owner>/<name> or local/<name>
  public static var modulesDirectory: URL { dataDirectory.appending(path: "modules") }

  public static var defaultConfig: String { String(decoding: PackageResources.config_default_toml, as: UTF8.self) }

  public static func config() throws -> Config {
    let file = configURL
    if !FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try defaultConfig.write(to: file, atomically: true, encoding: .utf8)
      FileHandle.standardError.write(Data("wpr: created \(file.path) — set `library` to your wallpapers folder\n".utf8))
    }
    let text = try String(contentsOf: file, encoding: .utf8)
    return try TOMLDecoder().decode(Config.self, from: text)
  }

}

// "30m", "2h", "900s", or bare seconds
public enum Interval {
  public static func parse(_ text: String) throws -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    let unit: Int
    let digits: Substring
    switch trimmed.last {
    case "h": unit = 3600; digits = trimmed.dropLast()
    case "m": unit = 60; digits = trimmed.dropLast()
    case "s": unit = 1; digits = trimmed.dropLast()
    default: unit = 1; digits = Substring(trimmed)
    }
    guard let number = Int(digits), number > 0 else { throw WPError("bad duration '\(text)' (try 30m, 2h, 900s)") }
    return number * unit
  }}
