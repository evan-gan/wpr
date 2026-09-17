import ArgumentParser
import Foundation
import WPCore

struct InstallCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install", abstract: "install a module from a local folder")

  @Argument(help: "a path (starts with ., /, or ~) to a folder containing module.toml") var source: String

  func run() throws {
    guard source.hasPrefix(".") || source.hasPrefix("/") || source.hasPrefix("~") else {
      throw ValidationError("only local paths for now; write it as ./name, /abs/path, or ~/path")
    }
    let folder = URL(filePath: (source as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: folder.appending(path: Module.manifestFile).path) else {
      throw ValidationError("no \(Module.manifestFile) in \(folder.path)")
    }
    let name = Module.name(fromRepository: folder.lastPathComponent)
    let link = Root.modulesDirectory.appending(path: "local/\(name)")
    guard !FileManager.default.fileExists(atPath: link.path) else { throw WPError("local/\(name) is already installed") }
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    print("installed local/\(name) -> \(folder.path)")
  }
}
