import Foundation
import ArgumentParser

struct SourcesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "sources", abstract: "list folders and modules and whether they're in rotation")

  func run() throws {
    let cfg = try Root.config()
    let index = try Index.load()
    let modules = try Module.discover()
    let counts = Dictionary(grouping: index.candidates.values, by: \.source).mapValues(\.count)
    let names = Set(counts.keys).union(modules.map(\.name))
    for n in names.sorted() {
      let on = cfg.sources.enabled.contains(n)
      let kind = modules.contains { $0.name == n } ? "module" : "folder"
      print("\(on ? "[x]" : "[ ]") \(n.pad(18)) \(kind.pad(7)) \(counts[n] ?? 0)")
    }
  }
}

struct EnableCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "enable", abstract: "add sources to the rotation")
  @Argument(help: "folder or module names") var sources: [String]
  func run() throws { try SourceToggle.set(sources, enabled: true) }
}

struct DisableCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "disable", abstract: "remove sources from the rotation")
  @Argument(help: "folder or module names") var sources: [String]
  func run() throws { try SourceToggle.set(sources, enabled: false) }
}

enum SourceToggle {
  // rewrites just the `enabled = [...]` line so the rest of config.toml (comments included) survives
  static func set(_ names: [String], enabled: Bool) throws {
    let known = Set(try Index.load().candidates.values.map(\.source)).union(try Module.discover().map(\.name))
    let unknown = names.filter { !known.contains($0) }
    guard unknown.isEmpty else {
      throw ValidationError("unknown source(s): \(unknown.joined(separator: ", ")). known: \(known.sorted().joined(separator: ", "))")
    }

    let url = try Root.url().appendingPathComponent("config.toml")
    var text = try String(contentsOf: url, encoding: .utf8)
    var list = try Root.config().sources.enabled
    for n in names {
      if enabled, !list.contains(n) { list.append(n) }
      if !enabled { list.removeAll { $0 == n } }
    }
    guard let range = text.range(of: #"(?m)^\s*enabled\s*=\s*\[[^\]]*\]"#, options: .regularExpression) else {
      throw WPError("couldn't find `enabled = [...]` in config.toml — edit it by hand")
    }
    text.replaceSubrange(range, with: "enabled = [" + list.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
    try text.write(to: url, atomically: true, encoding: .utf8)
    print("enabled: \(list.joined(separator: ", "))")
  }
}
