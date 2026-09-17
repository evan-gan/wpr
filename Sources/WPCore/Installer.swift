import Foundation

// where a module comes from: a git repository cloned to modules/<host>/<owner>/<name>, or a
// folder on this machine symlinked to modules/local/<name>
public enum ModuleSource {
  case repository(url: String, host: String, owner: String, name: String)
  case folder(URL)

  /// "owner/name" (github), "host/owner/name", any git url, or a path starting with . / ~
  public static func parse(_ text: String) throws -> ModuleSource {
    if text.hasPrefix(".") || text.hasPrefix("/") || text.hasPrefix("~") {
      return .folder(URL(filePath: (text as NSString).expandingTildeInPath).standardizedFileURL)
    }
    if let url = URL(string: text), let host = url.host, text.contains("://") {
      let parts = url.path.split(separator: "/").map(String.init)
      guard parts.count >= 2 else { throw WPError("can't tell owner/name from \(text)") }
      return .repository(url: text, host: host, owner: parts[parts.count - 2], name: Module.name(fromRepository: parts[parts.count - 1]))
    }
    if let colon = text.firstIndex(of: ":"), text.contains("@"), !text.contains("/", before: colon) {
      // git@host:owner/name.git
      let host = String(text[text.index(after: text.firstIndex(of: "@")!)..<colon])
      let parts = text[text.index(after: colon)...].split(separator: "/").map(String.init)
      guard parts.count == 2 else { throw WPError("can't tell owner/name from \(text)") }
      return .repository(url: text, host: host, owner: parts[0], name: Module.name(fromRepository: parts[1]))
    }
    let parts = text.split(separator: "/").map(String.init)
    switch parts.count {
    case 2: return .repository(url: "https://github.com/\(parts[0])/\(parts[1])", host: "github.com", owner: parts[0], name: Module.name(fromRepository: parts[1]))
    case 3 where parts[0].contains("."): return .repository(url: "https://\(text)", host: parts[0], owner: parts[1], name: Module.name(fromRepository: parts[2]))
    default: throw WPError("don't know how to install '\(text)': use owner/name, host/owner/name, a git url, or a path starting with ./ or /")
    }
  }

  public var fullName: String {
    switch self {
    case let .repository(_, host, owner, name): "\(host)/\(owner)/\(name)"
    case let .folder(url): "local/\(Module.name(fromRepository: url.lastPathComponent))"
    }
  }
}

public enum Installer {
  /// what a fresh machine gets, so `wpr next` has something to generate from
  public static let defaults = ["maxwofford/wpr-tunic", "maxwofford/wpr-melange", "maxwofford/wpr-wells", "maxwofford/wpr-neon-contours"]

  /// first run: no modules folder yet means nothing was ever installed, so install the defaults.
  /// the folder existing afterwards is the marker, even if everything gets uninstalled later
  public static func bootstrapIfNeeded() {
    let folder = Root.modulesDirectory
    guard !FileManager.default.fileExists(atPath: folder.path) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    FileHandle.standardError.write(Data("wpr: first run, installing the default modules\n".utf8))
    for name in defaults {
      do {
        let module = try install(try ModuleSource.parse(name))
        FileHandle.standardError.write(Data("  \(module.fullName)\n".utf8))
      } catch {
        FileHandle.standardError.write(Data("  \(name): \(error.localizedDescription)\n".utf8))
      }
    }
  }

  public static func install(_ source: ModuleSource) throws -> Module {
    let fileManager = FileManager.default
    let destination = Root.modulesDirectory.appending(path: source.fullName)
    guard !fileManager.fileExists(atPath: destination.path) else { throw WPError("\(source.fullName) is already installed") }
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    switch source {
    case let .folder(folder):
      guard fileManager.fileExists(atPath: folder.appending(path: Module.manifestFile).path) else {
        throw WPError("no \(Module.manifestFile) in \(folder.path)")
      }
      try fileManager.createSymbolicLink(at: destination, withDestinationURL: folder)
    case let .repository(url, _, _, _):
      let result = try git("clone", "--quiet", "--depth", "1", url, destination.path)
      guard result.status == 0 else {
        removeEmptyParents(of: destination)
        throw WPError("git clone failed:\n\(result.stderr)")
      }
      guard fileManager.fileExists(atPath: destination.appending(path: Module.manifestFile).path) else {
        try? fileManager.removeItem(at: destination)
        removeEmptyParents(of: destination)
        throw WPError("\(url) has no \(Module.manifestFile) at its root, so it isn't a wpr module")
      }
    }
    return try Module.named(source.fullName)
  }

  /// removes an installed module: a clone is trashed, a local symlink is just unlinked
  public static func uninstall(_ module: Module) throws {
    let fileManager = FileManager.default
    let attributes = try fileManager.attributesOfItem(atPath: module.directory.path)
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      try fileManager.removeItem(at: module.directory)
    } else {
      try fileManager.trashItem(at: module.directory, resultingItemURL: nil)
    }
    removeEmptyParents(of: module.directory)
  }

  /// git pull for a cloned module; nil for a local one, which is someone's working folder
  public static func update(_ module: Module) throws -> String? {
    guard !module.fullName.hasPrefix("local/") else { return nil }
    let before = try git("-C", module.directory.path, "rev-parse", "--short", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = try git("-C", module.directory.path, "pull", "--quiet", "--ff-only", "--no-rebase")
    guard result.status == 0 else { throw WPError("git pull failed for \(module.fullName):\n\(result.stderr)") }
    let after = try git("-C", module.directory.path, "rev-parse", "--short", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return before == after ? "up to date (\(after))" : "\(before) -> \(after)"
  }

  // <host>/<owner> folders that a failed or removed install left empty
  static func removeEmptyParents(of url: URL) {
    var directory = url.deletingLastPathComponent()
    while directory.path.hasPrefix(Root.modulesDirectory.path + "/"),
          (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
      try? FileManager.default.removeItem(at: directory)
      directory = directory.deletingLastPathComponent()
    }
  }

  static func git(_ arguments: String...) throws -> Subprocess.Result {
    try Subprocess.run(executable: "/usr/bin/git", arguments: arguments)
  }
}

private extension String {
  func contains(_ character: Character, before index: String.Index) -> Bool {
    self[..<index].contains(character)
  }
}
