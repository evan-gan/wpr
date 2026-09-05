import AppKit
import ArgumentParser

struct DisplaysCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "displays", abstract: "list connected displays and what's on them")

  func run() throws {
    for s in Screen.all {
      let px = s.pixelSize, pt = s.pointSize
      print("\(s.index)  \(s.name)\(s.isMain ? "  (main)" : "")")
      print("   \(px.w)x\(px.h) px   \(pt.w)x\(pt.h) pt @\(Int(s.scale))x   aspect \(String(format: "%.3f", s.aspect))")
      print("   uuid \(s.uuid)")
      if let wp = s.currentWallpaper {
        print("   wallpaper \(wp.path)  [\(Fill.describe(s.currentOptions))]")
      }
    }
  }
}

struct SetCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "set", abstract: "set an image as wallpaper")

  @Argument(help: "path to an image") var image: String
  @Option(name: .shortAndLong, help: "display index, name substring, or 'all'") var display: String?
  @Option(name: .shortAndLong, help: "how to fit the image: \(Fill.allCases.map(\.rawValue).joined(separator: "|"))") var fill: Fill = .crop

  func run() throws {
    let url = URL(fileURLWithPath: (image as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ValidationError("no such file: \(url.path)")
    }
    for s in try Screen.select(display) {
      try NSWorkspace.shared.setDesktopImageURL(url, for: s.nsScreen, options: fill.options)
      print("\(s.index) \(s.name) <- \(url.lastPathComponent)  [\(fill.rawValue)]")
    }
  }
}
