import Foundation
import ArgumentParser

struct TimerCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "timer",
    abstract: "run `wpr tick` on a schedule via launchd",
    subcommands: [Install.self, Uninstall.self, Status.self],
    defaultSubcommand: Status.self
  )

  static let label = "com.maxwofford.wpr"
  static var plistURL: URL { URL.homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist") }
  static var logURL: URL { URL.libraryDirectory.appending(path: "Logs/wpr.log") }
  static var domain: String { "gui/\(getuid())" }

  struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "install (or reinstall) the launch agent")

    @Option(name: .long, help: "interval like 30m, 2h, 900s (default: rotation.interval from config)") var every: String?

    func run() throws {
      let configuration = try Root.config()
      let seconds = try parseDuration(every ?? configuration.rotation.interval)
      // launchd runs whichever binary installed it
      guard let program = Bundle.main.executableURL else { throw WPError("can't tell where this binary is") }
      let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [program.path, "tick"],
        "StartInterval": seconds,
        "RunAtLoad": true,
        "StandardOutPath": logURL.path,
        "StandardErrorPath": logURL.path,
      ]
      try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      _ = launchctl("bootout", "\(domain)/\(label)")
      try data.write(to: plistURL)
      let result = launchctl("bootstrap", domain, plistURL.path)
      guard result.status == 0 else { throw WPError("launchctl bootstrap failed: \(result.stderr)") }
      print("installed \(label): `\(program.path) tick` every \(every ?? configuration.rotation.interval), log at \(logURL.path)")
    }
  }

  struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "remove the launch agent")

    func run() throws {
      _ = launchctl("bootout", "\(domain)/\(label)")
      if FileManager.default.fileExists(atPath: plistURL.path) {
        try FileManager.default.trashItem(at: plistURL, resultingItemURL: nil)
      }
      print("removed \(label)")
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "show whether the agent is loaded and the recent log")

    func run() throws {
      let result = launchctl("print", "\(domain)/\(label)")
      if result.status == 0 {
        let interesting = result.stdout.split(separator: "\n").filter {
          $0.contains("state =") || $0.contains("run interval") || $0.contains("last exit") || $0.contains("runs =")
        }
        print("loaded: \(label)")
        for line in interesting { print("  \(line.trimmingCharacters(in: .whitespaces))") }
      } else {
        print("not loaded (\(plistURL.path) \(FileManager.default.fileExists(atPath: plistURL.path) ? "exists" : "missing"))")
      }
      print("power: \(Power.isOnAC() ? "AC" : "battery")")
      if let configuration = try? Root.config(), let index = try? Index.load() {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        for screen in Screen.all {
          if let until = index.heldUntil(screen, hold: configuration.rotation.holdManualSeconds) {
            print("hold: \(screen.index) \(screen.name) set by hand, rotation resumes \(clock.string(from: until))")
          }
        }
      }
      if let log = try? String(contentsOf: logURL, encoding: .utf8) {
        let tail = log.split(separator: "\n").suffix(8)
        if !tail.isEmpty { print("recent log:"); for line in tail { print("  \(line)") } }
      }
    }
  }

  static func launchctl(_ arguments: String...) -> Subprocess.Result {
    (try? Subprocess.run(executable: "/bin/launchctl", arguments: arguments))
      ?? Subprocess.Result(status: -1, stdout: "", stderr: "couldn't run launchctl")
  }

  static func parseDuration(_ text: String) throws -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    let unit: Int
    let digits: Substring
    switch trimmed.last {
    case "h": unit = 3600; digits = trimmed.dropLast()
    case "m": unit = 60; digits = trimmed.dropLast()
    case "s": unit = 1; digits = trimmed.dropLast()
    default: unit = 1; digits = Substring(trimmed)
    }
    guard let number = Int(digits), number > 0 else { throw ValidationError("bad duration '\(text)' (try 30m, 2h, 900s)") }
    return number * unit
  }
}
