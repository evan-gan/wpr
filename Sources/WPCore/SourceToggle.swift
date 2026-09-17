import Foundation
public enum SourceToggle {
  // rewrites just the `enabled = [...]` line so the rest of config.toml (comments included) survives
  public static func set(_ names: [String], enabled: Bool) throws {
    let known = Set(try Index.load().candidates.values.map(\.source)).union(try Module.discover().map(\.name))
    let unknown = names.filter { !known.contains($0) }
    guard unknown.isEmpty else {
      throw WPError("unknown source(s): \(unknown.joined(separator: ", ")). known: \(known.sorted().joined(separator: ", "))")
    }

    let url = Root.configURL
    var text = try String(contentsOf: url, encoding: .utf8)
    var list = try Root.config().sources.enabled
    for name in names {
      if enabled, !list.contains(name) { list.append(name) }
      if !enabled { list.removeAll { $0 == name } }
    }
    guard let range = text.range(of: #"(?m)^\s*enabled\s*=\s*\[[^\]]*\]"#, options: .regularExpression) else {
      throw WPError("couldn't find `enabled = [...]` in \(url.path) — edit it by hand")
    }
    text.replaceSubrange(range, with: "enabled = [" + list.map { "\"\($0)\"" }.joined(separator: ", ") + "]")
    try text.write(to: url, atomically: true, encoding: .utf8)
    print("enabled: \(list.joined(separator: ", "))")
  }
}
