import AppKit
import ArgumentParser

struct TickCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tick",
    abstract: "one rotation step: top up the generated pool (on AC power only), prune, then set new wallpapers"
  )

  @Flag(name: .long, help: "generate even on battery") var forceGenerate = false
  @Flag(name: .long, help: "don't change wallpapers, just maintain the pool") var noRotate = false

  func run() throws {
    let cfg = try Root.config()
    var index = try Index.load()
    let screens = Screen.all
    let stamp = ISO8601DateFormatter().string(from: Date())
    func log(_ s: String) { print("\(stamp) \(s)") }

    if Power.isOnAC() || forceGenerate {
      let modules = try Module.discover().filter { cfg.sources.enabled.contains($0.name) }
      let onScreen = Set(screens.compactMap { $0.currentWallpaper?.standardizedFileURL.path })
      for m in modules {
        for s in screens {
          let (w, h) = s.pixelSize
          let existing = index.candidates.values.filter { $0.module == m.name && $0.width == w && $0.height == h }
          if existing.filter({ $0.shownCount == 0 }).count < cfg.pool.perModule {
            let seed = UInt32.random(in: 0..<16_000_000)
            let url = cfg.generatedURL.appendingPathComponent("\(m.name)-\(seed)-\(w)x\(h).png")
            let start = Date()
            do {
              try Generator.generate(m, width: w, height: h, seed: seed, params: [], to: url, verbose: false)
              index.add(generated: url, module: m, seed: seed, width: w, height: h)
              log("generated \(url.lastPathComponent) (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
            } catch {
              log("FAILED \(m.name) \(w)x\(h): \(error)")
            }
          }

          let oldestFirst = index.candidates.values
            .filter { $0.module == m.name && $0.width == w && $0.height == h }
            .sorted { $0.indexedAt < $1.indexedAt }
          var excess = oldestFirst.count - cfg.pool.keep
          for c in oldestFirst where excess > 0 && !onScreen.contains(c.path) {
            do {
              try FileManager.default.trashItem(at: c.url, resultingItemURL: nil)
              index.candidates.removeValue(forKey: c.path)
              excess -= 1
              log("trashed \(c.name)")
            } catch {
              log("couldn't trash \(c.name): \(error.localizedDescription)")
            }
          }
        }
      }
    } else {
      log("on battery; skipping generation")
    }

    if !noRotate {
      let picker = Picker(cfg: cfg, index: index)
      var used = Set<String>()
      for s in screens {
        guard let e = picker.pick(for: s, source: nil, avoiding: used) else {
          log("\(s.index) \(s.name): nothing eligible")
          continue
        }
        used.insert(e.c.path)
        try NSWorkspace.shared.setDesktopImageURL(e.c.url, for: s.nsScreen, options: Fill.crop.options)
        index.markShown(e.c.path)
        log("\(s.index) \(s.name) <- \(e.c.source)/\(e.c.name)")
      }
    }
    try index.save()
  }
}
