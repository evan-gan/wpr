import Foundation
import TOMLKit

// a generator: a folder with a module.toml and an entry file. installed under the modules
// directory as <host>/<owner>/<name> (or local/<name> for a symlinked folder); the folder path
// is the module's identity and its last component is the short name
public struct Module {
  public struct Manifest: Decodable {
    public let description: String
    public let host: Host
    public let entry: String
    public let timeoutMs: Int?
    private enum CodingKeys: String, CodingKey { case description, host, entry, timeoutMs = "timeout_ms" }
  }

  public enum Host: String, Decodable { case metal, web }

  public let manifest: Manifest
  /// e.g. "github.com/maxwofford/aurora" or "local/aurora"
  public let fullName: String
  public let directory: URL

  public var name: String { String(fullName.split(separator: "/").last ?? Substring(fullName)) }
  public var description: String { manifest.description }
  public var host: Host { manifest.host }
  public var timeoutMs: Int? { manifest.timeoutMs }
  public var entryURL: URL { directory.appendingPathComponent(manifest.entry) }

  public static let manifestFile = "module.toml"

  /// a repository called wpr-aurora is the module aurora, the way homebrew-x is the tap x
  public static func name(fromRepository repository: String) -> String {
    var name = repository
    if name.hasSuffix(".git") { name.removeLast(4) }
    if name.hasPrefix("wpr-") { name.removeFirst(4) }
    return name
  }

  public static func discover() throws -> [Module] {
    var found: [Module] = []
    try walk(Root.modulesDirectory, components: [], depth: 0, into: &found)
    return found.sorted { $0.fullName < $1.fullName }
  }

  // a module.toml anywhere up to three folders deep: host/owner/name, or local/name
  private static func walk(_ directory: URL, components: [String], depth: Int, into found: inout [Module]) throws {
    let fileManager = FileManager.default
    let manifest = directory.appendingPathComponent(manifestFile)
    if !components.isEmpty, fileManager.fileExists(atPath: manifest.path) {
      let decoded = try TOMLDecoder().decode(Manifest.self, from: String(contentsOf: manifest, encoding: .utf8))
      found.append(Module(manifest: decoded, fullName: components.joined(separator: "/"), directory: directory))
      return
    }
    guard depth < 3, let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
    for name in names.sorted() where !name.hasPrefix(".") {
      try walk(directory.appendingPathComponent(name), components: components + [name], depth: depth + 1, into: &found)
    }
  }

  /// "aurora" matches any */aurora; "maxwofford/aurora" narrows it; the full name is exact
  public static func named(_ name: String) throws -> Module {
    let all = try discover()
    let matches = all.filter { $0.fullName == name || $0.fullName.hasSuffix("/" + name) }
    switch matches.count {
    case 1: return matches[0]
    case 0: throw WPError("no module '\(name)' (have: \(all.map(\.fullName).joined(separator: ", ")))")
    default: throw WPError("'\(name)' is ambiguous: \(matches.map(\.fullName).joined(separator: ", "))")
    }
  }
}
