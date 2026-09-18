import AppKit
import ArgumentParser
import WPCore

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
  @OptionGroup var spaces: SpacesOption

  func run() throws {
    let url = URL(fileURLWithPath: (image as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ValidationError("no such file: \(url.path)")
    }
    let configuration = try Root.config()
    var index = try Index.load()
    var applied: [String: URL] = [:]
    for screen in try Screen.select(display) {
      try NSWorkspace.shared.setDesktopImageURL(url, for: screen.nsScreen, options: fill.options)
      applied[screen.uuid] = url
      index.markShown(url.standardizedFileURL.path)
      index.markManual(screen)
      print("\(screen.index) \(screen.name) <- \(url.lastPathComponent)  [\(fill.rawValue)]")
    }
    try index.save()
    try spaces.spread(applied, configuration: configuration)
  }
}

struct NextCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "next", abstract: "pick a new wallpaper for each display, aspect-aware")

  @Option(name: .shortAndLong, help: "display index, name substring, or 'all'") var display: String?
  @Option(name: .shortAndLong, help: "restrict to one source (folder or module)") var source: String?
  @Flag(name: .long, help: "print the pick without setting it") var dryRun = false
  @OptionGroup var spaces: SpacesOption

  func run() async throws {
    let configuration = try Root.config()
    var index = try Index.load()
    let picker = Picker(configuration: configuration, index: index)
    var used = Set<String>()
    var applied: [String: URL] = [:]
    for screen in try Screen.select(display) {
      guard let entry = picker.pick(for: screen, source: source, avoiding: used) else {
        if let url = try await generateFresh(for: screen, configuration: configuration, index: &index) {
          applied[screen.uuid] = url
        }
        continue
      }
      let candidate = entry.candidate
      used.insert(candidate.path)
      let luminance = candidate.palette.map { String(format: " lum %.2f", $0.luminance) } ?? ""
      print("\(screen.index) \(screen.name) <- \(candidate.source)/\(candidate.name)  fit \(String(format: "%.2f", entry.fit)) res \(String(format: "%.2f", entry.resolution))\(luminance)\(dryRun ? "  (dry run)" : "")")
      if !dryRun {
        try NSWorkspace.shared.setDesktopImageURL(candidate.url, for: screen.nsScreen, options: Fill.crop.options)
        applied[screen.uuid] = candidate.url
        index.markShown(candidate.path)
        index.markManual(screen)
      }
    }
    if !dryRun {
      try index.save()
      try spaces.spread(applied, configuration: configuration)
    }
  }

  // nothing in the pool fits this display: render one from an enabled module right now, so a
  // fresh install (or a new display) gets a wallpaper on the first `next` instead of a shrug
  // returns the file it set, or nil if it had nothing to generate from (or was a dry run)
  private func generateFresh(for screen: Screen, configuration: Config, index: inout Index) async throws -> URL? {
    let enabled = try Module.discover().filter { configuration.sources.enabled.contains($0.name) && (source == nil || $0.name == source) }
    guard let module = enabled.randomElement() else {
      print("\(screen.index) \(screen.name): nothing eligible and no enabled modules (enabled: \(configuration.sources.enabled.joined(separator: ", ")))")
      return nil
    }
    let seed = UInt32.random(in: 0..<16_000_000)
    let (width, height) = screen.pixelSize
    if dryRun {
      print("\(screen.index) \(screen.name): nothing in the pool; would generate \(module.name) seed \(seed)  (dry run)")
      return nil
    }
    let url = configuration.generatedURL.appendingPathComponent("\(module.name)-\(seed)-\(width)x\(height).png")
    try await Generator.generate(module, width: width, height: height, seed: seed, params: [], to: url, verbose: false)
    index.add(generated: url, module: module, seed: seed, width: width, height: height)
    try NSWorkspace.shared.setDesktopImageURL(url, for: screen.nsScreen, options: Fill.crop.options)
    index.markShown(url.standardizedFileURL.path)
    index.markManual(screen)
    print("\(screen.index) \(screen.name) <- \(module.name)/\(url.lastPathComponent)  (generated now)")
    return url
  }
}

struct LsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ls", abstract: "list indexed wallpapers, optionally scored against a display")

  @Option(name: .long, help: "score fit against this display (index or name)") var fit: String?
  @Option(name: .shortAndLong, help: "only this source") var source: String?
  @Flag(name: .long, help: "include disabled sources") var all = false

  func run() throws {
    let configuration = try Root.config()
    let index = try Index.load()
    var rows = index.candidates.values.filter { candidate in
      (all || configuration.sources.enabled.contains(candidate.source)) && (source == nil || candidate.source == source)
    }
    if let fit, let screen = try Screen.select(fit).first {
      rows.sort {
        Fit.score(imageAspect: $0.aspect, displayAspect: screen.aspect) > Fit.score(imageAspect: $1.aspect, displayAspect: screen.aspect)
      }
      print("   fit   res   lum   size         source            name")
      for candidate in rows {
        let fitScore = Fit.score(imageAspect: candidate.aspect, displayAspect: screen.aspect)
        let resolution = Fit.resolution(candidate, screen)
        let eligible = fitScore >= configuration.rotation.minFit && resolution >= configuration.rotation.minRes && Fit.sizeAllowed(candidate, screen)
        print("\(eligible ? " " : "x") \(String(format: "%.2f  %.2f  %@", fitScore, resolution, luminanceText(candidate)))  \("\(candidate.width)x\(candidate.height)".pad(11))  \(candidate.source.pad(16))  \(candidate.name)")
      }
    } else {
      rows.sort { ($0.source, $0.name) < ($1.source, $1.name) }
      print("lum   size         source            name")
      for candidate in rows {
        print("\(luminanceText(candidate))  \("\(candidate.width)x\(candidate.height)".pad(11))  \(candidate.source.pad(16))  \(candidate.name)")
      }
    }
    print("\(rows.count) candidates")
  }

  private func luminanceText(_ candidate: Candidate) -> String {
    candidate.palette.map { String(format: "%.2f", $0.luminance) } ?? " -- "
  }
}

struct ScanCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "scan", abstract: "re-index the library and generated wallpapers")

  @Flag(name: .shortAndLong) var verbose = false

  func run() throws {
    var index = (try? Index.load()) ?? Index()
    try index.scan(verbose: verbose)
    try index.save()
    let counts = Dictionary(grouping: index.candidates.values, by: \.source).mapValues(\.count)
    for (source, count) in counts.sorted(by: { $0.key < $1.key }) { print("\(source.pad(18)) \(count)") }
    print("\(index.candidates.count) candidates -> \(Index.fileURL.path)")
  }
}

extension String {
  func pad(_ width: Int) -> String {
    count >= width ? self : self + String(repeating: " ", count: width - count)
  }
}
