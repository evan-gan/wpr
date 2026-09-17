import Foundation
import ArgumentParser
import TOMLKit

struct Module: Decodable {
  let name: String
  let description: String
  let host: Host
  let entry: String
  let timeoutMs: Int?
  var directory = URL(fileURLWithPath: "/")

  enum Host: String, Decodable { case metal, web }

  private enum CodingKeys: String, CodingKey { case name, description, host, entry, timeoutMs = "timeout_ms" }

  var entryURL: URL { directory.appendingPathComponent(entry) }

  static func discover() throws -> [Module] {
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

  static func named(_ name: String) throws -> Module {
    let all = try discover()
    guard let module = all.first(where: { $0.name == name }) else {
      throw ValidationError("no module '\(name)' (have: \(all.map(\.name).joined(separator: ", ")))")
    }
    return module
  }
}
