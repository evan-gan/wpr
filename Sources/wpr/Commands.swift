import AppKit
import ArgumentParser

struct DisplaysCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "displays", abstract: "list connected displays and what's on them")

  func run() throws {
    for screen in Screen.all {
      let pixels = screen.pixelSize, points = screen.pointSize
      print("\(screen.index)  \(screen.name)\(screen.isMain ? "  (main)" : "")")
      print("   \(pixels.w)x\(pixels.h) px   \(points.w)x\(points.h) pt @\(Int(screen.scale))x   aspect \(String(format: "%.3f", screen.aspect))")
      print("   uuid \(screen.uuid)")
      if let wallpaper = screen.currentWallpaper {
        print("   wallpaper \(wallpaper.path)  [\(Fill.describe(screen.currentOptions))]")
      }
    }
  }
}

struct RmCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rm", abstract: "trash a generated wallpaper and forget it")

  @Argument(help: "paths of generated images (library images are never touched)") var paths: [String]

  func run() throws {
    var index = try Index.load()
    for argument in paths {
      let path = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath).standardizedFileURL.path
      guard let candidate = index.candidates[path] else { throw ValidationError("not in the index: \(path)") }
      guard candidate.kind == .generated else { throw ValidationError("\(candidate.name) is a library image; disable its source instead") }
      try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
      index.candidates.removeValue(forKey: path)
      print("trashed \(candidate.source)/\(candidate.name)")
    }
    try index.save()
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
    var index = try Index.load()
    for screen in try Screen.select(display) {
      try NSWorkspace.shared.setDesktopImageURL(url, for: screen.nsScreen, options: fill.options)
      index.markShown(url.standardizedFileURL.path)
      index.markManual(screen)
      print("\(screen.index) \(screen.name) <- \(url.lastPathComponent)  [\(fill.rawValue)]")
    }
    try index.save()
  }
}
