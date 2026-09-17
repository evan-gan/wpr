import ArgumentParser
import WPCore

struct InstallCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "install", abstract: "install a module from a git repository or a local folder")

  @Argument(help: "owner/name (github), host/owner/name, a git url, or a path starting with ./ or /") var source: String

  func run() throws {
    let source = try ModuleSource.parse(source)
    let module = try Installer.install(source)
    print("installed \(module.fullName) -> \(module.directory.path)")
  }
}

struct UninstallCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "remove an installed module")

  @Argument(help: "module name (see `wpr modules`)") var module: String

  func run() throws {
    let module = try Module.named(module)
    try Installer.uninstall(module)
    print("removed \(module.fullName)")
  }
}

struct UpdateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "update", abstract: "git pull every cloned module, or just the ones named")

  @Argument(help: "module names; all cloned modules if omitted") var modules: [String] = []

  func run() throws {
    let targets = try modules.isEmpty ? Module.discover() : modules.map(Module.named)
    for module in targets {
      if let outcome = try Installer.update(module) { print("\(module.fullName.pad(28)) \(outcome)") }
    }
  }
}
