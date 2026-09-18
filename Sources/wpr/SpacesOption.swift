import ArgumentParser
import Foundation
import WPCore

// shared by every command that sets a wallpaper, so they all honour the same flag and config key
struct SpacesOption: ParsableArguments {
  @Flag(inversion: .prefixedNo, help: "set every Space, not just the current one (default: rotation.all_spaces in config)")
  var allSpaces: Bool?

  func isEnabled(_ configuration: Config) -> Bool { allSpaces ?? configuration.rotation.allSpaces }

  /// copy what was just set (display uuid -> image) to every Space, if enabled
  func spread(_ wallpapers: [String: URL], configuration: Config) throws {
    guard isEnabled(configuration) else { return }
    try AllSpaces.apply(wallpapers)
  }
}
