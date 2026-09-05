import ArgumentParser

@main
struct WP: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wp",
    abstract: "max's wallpaper manager",
    groupedSubcommands: [
      CommandGroup(name: "wallpapers", subcommands: [NextCommand.self, SetCommand.self, LsCommand.self, DisplaysCommand.self]),
      CommandGroup(name: "sources", subcommands: [SourcesCommand.self, EnableCommand.self, DisableCommand.self, ScanCommand.self]),
      CommandGroup(name: "generators", subcommands: [GenCommand.self, ModulesCommand.self]),
      CommandGroup(name: "automation", subcommands: [TickCommand.self, TimerCommand.self]),
    ]
  )
}
