import Foundation
import ArgumentParser
import TOMLKit

struct Module: Decodable {
  let name: String
  let description: String
  let host: Host
  let entry: String
  let timeoutMs: Int?
  var dir = URL(fileURLWithPath: "/")

  enum Host: String, Decodable { case metal, web, exec }

  private enum CodingKeys: String, CodingKey { case name, description, host, entry, timeoutMs = "timeout_ms" }

  var entryURL: URL { dir.appendingPathComponent(entry) }

  static func discover() throws -> [Module] {
    let fm = FileManager.default
    let dir = try Root.modulesDir()
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
    return try names.sorted().compactMap { n -> Module? in
      let d = dir.appendingPathComponent(n)
      let manifest = d.appendingPathComponent("module.toml")
      guard fm.fileExists(atPath: manifest.path) else { return nil }
      var m = try TOMLDecoder().decode(Module.self, from: String(contentsOf: manifest, encoding: .utf8))
      m.dir = d
      return m
    }
  }

  static func named(_ name: String) throws -> Module {
    let all = try discover()
    guard let m = all.first(where: { $0.name == name }) else {
      throw ValidationError("no module '\(name)' (have: \(all.map(\.name).joined(separator: ", ")))")
    }
    return m
  }
}
