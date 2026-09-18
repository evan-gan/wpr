import AppKit
import ArgumentParser
import WPCore

struct TickCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tick",
    abstract: "one rotation step: top up the generated pool (on AC power only), prune, then set new wallpapers"
  )

  @Flag(name: .long, help: "generate even on battery") var forceGenerate = false
  @Flag(name: .long, help: "don't change wallpapers, just maintain the pool") var noRotate = false
  @OptionGroup var spaces: SpacesOption

  func run() async throws {
    let configuration = try Root.config()
    var index = try Index.load()
    let screens = Screen.all
    let stamp = ISO8601DateFormatter().string(from: Date())
    func log(_ line: String) { print("\(stamp) \(line)") }

    if Power.isOnAC() || forceGenerate {
      let modules = try Module.discover().filter { configuration.sources.enabled.contains($0.name) }
      let onScreen = Set(screens.compactMap { $0.currentWallpaper?.standardizedFileURL.path })
      for module in modules {
        for screen in screens {
          let (width, height) = screen.pixelSize
          let existing = index.candidates.values.filter { $0.module == module.name && $0.width == width && $0.height == height }
          if existing.filter({ $0.shownCount == 0 }).count < configuration.pool.perModule {
            let seed = UInt32.random(in: 0..<16_000_000)
            let url = configuration.generatedURL.appendingPathComponent("\(module.name)-\(seed)-\(width)x\(height).png")
            let start = Date()
            do {
              try await Generator.generate(module, width: width, height: height, seed: seed, params: [], to: url, verbose: false)
              index.add(generated: url, module: module, seed: seed, width: width, height: height)
              log("generated \(url.lastPathComponent) (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
            } catch {
              log("FAILED \(module.name) \(width)x\(height): \(error)")
            }
          }

          let oldestFirst = index.candidates.values
            .filter { $0.module == module.name && $0.width == width && $0.height == height }
            .sorted { $0.indexedAt < $1.indexedAt }
          var excess = oldestFirst.count - configuration.pool.keep
          for candidate in oldestFirst where excess > 0 && !onScreen.contains(candidate.path) {
            do {
              try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
              index.candidates.removeValue(forKey: candidate.path)
              excess -= 1
              log("trashed \(candidate.name)")
            } catch {
              log("couldn't trash \(candidate.name): \(error.localizedDescription)")
            }
          }
        }
      }
    } else {
      log("on battery; skipping generation")
    }

    var applied: [String: URL] = [:]
    if !noRotate {
      let picker = Picker(configuration: configuration, index: index)
      var used = Set<String>()
      let clock = DateFormatter()
      clock.dateFormat = "HH:mm"
      for screen in screens {
        if let until = index.heldUntil(screen, hold: configuration.rotation.holdManualSeconds) {
          log("\(screen.index) \(screen.name): set by hand, holding until \(clock.string(from: until))")
          continue
        }
        guard let entry = picker.pick(for: screen, source: nil, avoiding: used) else {
          log("\(screen.index) \(screen.name): nothing eligible")
          continue
        }
        used.insert(entry.candidate.path)
        try NSWorkspace.shared.setDesktopImageURL(entry.candidate.url, for: screen.nsScreen, options: Fill.crop.options)
        applied[screen.uuid] = entry.candidate.url
        index.markShown(entry.candidate.path)
        log("\(screen.index) \(screen.name) <- \(entry.candidate.source)/\(entry.candidate.name)")
      }
    }
    try index.save()
    // log instead of throwing: the current Space already changed, and launchd only keeps the log
    do {
      try spaces.spread(applied, configuration: configuration)
    } catch {
      log("couldn't copy to other Spaces: \(error)")
    }
  }
}
