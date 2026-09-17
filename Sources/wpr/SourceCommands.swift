import ArgumentParser

struct SourcesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "sources", abstract: "list folders and modules and whether they're in rotation")

  func run() throws {
    let configuration = try Root.config()
    let index = try Index.load()
    let modules = try Module.discover()
    let counts = Dictionary(grouping: index.candidates.values, by: \.source).mapValues(\.count)
    let names = Set(counts.keys).union(modules.map(\.name))
    for name in names.sorted() {
      let enabled = configuration.sources.enabled.contains(name)
      let kind = modules.contains { $0.name == name } ? "module" : "folder"
      print("\(enabled ? "[x]" : "[ ]") \(name.pad(18)) \(kind.pad(7)) \(counts[name] ?? 0)")
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
