import Foundation
import TOMLKit

public struct Module: Decodable {
  public let name: String
  public let description: String
  public let host: Host
  public let entry: String
  public let timeoutMs: Int?
  public var directory = URL(fileURLWithPath: "/")

  public enum Host: String, Decodable { case metal, web }

  private enum CodingKeys: String, CodingKey { case name, description, host, entry, timeoutMs = "timeout_ms" }

  public var entryURL: URL { directory.appendingPathComponent(entry) }

  public static func discover() throws -> [Module] {
    let fileManager = FileManager.default
    let modulesDirectory = try Root.modulesDir()
    guard let folderNames = try? fileManager.contentsOfDirectory(atPath: modulesDirectory.path) else { return [] }
    return try folderNames.sorted().compactMap { folderName -> Module? in
      let directory = modulesDirectory.appendingPathComponent(folderName)
      let manifest = directory.appendingPathComponent("module.toml")
      guard fileManager.fileExists(atPath: manifest.path) else { return nil }
      var module = try TOMLDecoder().decode(Module.self, from: String(contentsOf: manifest, encoding: .utf8))
      module.directory = directory
      return module
    }
  }

  public static func named(_ name: String) throws -> Module {
    let all = try discover()
    guard let module = all.first(where: { $0.name == name }) else {
      throw WPError("no module '\(name)' (have: \(all.map(\.name).joined(separator: ", ")))")
    }
    return module
  }
}
