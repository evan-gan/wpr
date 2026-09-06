import AppKit
import ArgumentParser

enum Fit {
  // fraction of the image's area that survives a center-crop onto the display
  static func score(imageAspect: Double, displayAspect: Double) -> Double {
    min(imageAspect / displayAspect, displayAspect / imageAspect)
  }

  // 1.0 when the image has at least the display's pixels on both axes; below that it'll be upscaled
  static func resolution(_ c: Candidate, _ s: Screen) -> Double {
    min(1.0, Double(c.width) / Double(s.pixelSize.w), Double(c.height) / Double(s.pixelSize.h))
  }

  // generated images were rendered for one exact display; never crop them onto another
  static func sizeAllowed(_ c: Candidate, _ s: Screen) -> Bool {
    c.kind != .generated || (c.width == s.pixelSize.w && c.height == s.pixelSize.h)
  }
}

struct Picker {
  let cfg: Config
  let index: Index

  struct Entry { let c: Candidate; let fit: Double; let res: Double }

  func eligible(for s: Screen, source: String?) -> [Entry] {
    index.candidates.values.compactMap { c in
      guard cfg.sources.enabled.contains(c.source) else { return nil }
      if let source, c.source != source { return nil }
      guard Fit.sizeAllowed(c, s) else { return nil }
      let fit = Fit.score(imageAspect: c.aspect, displayAspect: s.aspect)
      let res = Fit.resolution(c, s)
      guard fit >= cfg.rotation.minFit, res >= cfg.rotation.minRes else { return nil }
      return Entry(c: c, fit: fit, res: res)
    }
  }

  // two stages: pick a source (weighted by sqrt of its eligible count, so big folders don't drown
  // small ones), then an image within it favoring fit, resolution, and not-recently-shown
  func pick(for s: Screen, source: String?, avoiding: Set<String>) -> Entry? {
    let pool = eligible(for: s, source: source).filter { !avoiding.contains($0.c.path) }
    guard !pool.isEmpty else { return nil }
    let bySource = Dictionary(grouping: pool, by: \.c.source)
    let sources = Array(bySource.keys)
    guard let chosen = weighted(sources, sources.map { Double(bySource[$0]!.count).squareRoot() }) else { return nil }
    let group = bySource[chosen]!
    let now = Date()
    let dark: Bool? = cfg.rotation.matchAppearance ? Appearance.isDark : nil
    let weights = group.map { e -> Double in
      let recency = e.c.lastShown.map { min(1.0, now.timeIntervalSince($0) / 86400) } ?? 1.0
      var w = e.fit * (0.5 + 0.5 * e.res) * (0.15 + 0.85 * recency)
      if let dark, let lum = e.c.palette?.luminance {
        w *= 0.05 + 0.95 * Appearance.preference(luminance: lum, dark: dark)
      }
      return w
    }
    return weighted(group, weights)
  }

  private func weighted<T>(_ items: [T], _ weights: [Double]) -> T? {
    guard !items.isEmpty else { return nil }
    var r = Double.random(in: 0..<weights.reduce(0, +))
    for (item, w) in zip(items, weights) {
      r -= w
      if r <= 0 { return item }
    }
    return items.last
  }
}

struct NextCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "next", abstract: "pick a new wallpaper for each display, aspect-aware")

  @Option(name: .shortAndLong, help: "display index, name substring, or 'all'") var display: String?
  @Option(name: .shortAndLong, help: "restrict to one source (folder or module)") var source: String?
  @Flag(name: .long, help: "print the pick without setting it") var dryRun = false

  func run() throws {
    let cfg = try Root.config()
    var index = try Index.load()
    let picker = Picker(cfg: cfg, index: index)
    var used = Set<String>()
    for s in try Screen.select(display) {
      guard let e = picker.pick(for: s, source: source, avoiding: used) else {
        print("\(s.index) \(s.name): nothing eligible (enabled: \(cfg.sources.enabled.joined(separator: ", ")))")
        continue
      }
      used.insert(e.c.path)
      let lum = e.c.palette.map { String(format: " lum %.2f", $0.luminance) } ?? ""
      print("\(s.index) \(s.name) <- \(e.c.source)/\(e.c.name)  fit \(String(format: "%.2f", e.fit)) res \(String(format: "%.2f", e.res))\(lum)\(dryRun ? "  (dry run)" : "")")
      if !dryRun {
        try NSWorkspace.shared.setDesktopImageURL(e.c.url, for: s.nsScreen, options: Fill.crop.options)
        index.markShown(e.c.path)
        index.markManual(s)
      }
    }
    if !dryRun { try index.save() }
  }
}

struct LsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "ls", abstract: "list indexed wallpapers, optionally scored against a display")

  @Option(name: .long, help: "score fit against this display (index or name)") var fit: String?
  @Option(name: .shortAndLong, help: "only this source") var source: String?
  @Flag(name: .long, help: "include disabled sources") var all = false

  func run() throws {
    let cfg = try Root.config()
    let index = try Index.load()
    var rows = index.candidates.values.filter { c in
      (all || cfg.sources.enabled.contains(c.source)) && (source == nil || c.source == source)
    }
    if let fit, let screen = try Screen.select(fit).first {
      rows.sort {
        Fit.score(imageAspect: $0.aspect, displayAspect: screen.aspect) > Fit.score(imageAspect: $1.aspect, displayAspect: screen.aspect)
      }
      print("   fit   res   lum   size         source            name")
      for c in rows {
        let f = Fit.score(imageAspect: c.aspect, displayAspect: screen.aspect)
        let r = Fit.resolution(c, screen)
        let mark = (f < cfg.rotation.minFit || r < cfg.rotation.minRes || !Fit.sizeAllowed(c, screen)) ? "x" : " "
        print("\(mark) \(String(format: "%.2f  %.2f  %@", f, r, lumText(c)))  \("\(c.width)x\(c.height)".pad(11))  \(c.source.pad(16))  \(c.name)")
      }
    } else {
      rows.sort { ($0.source, $0.name) < ($1.source, $1.name) }
      print("lum   size         source            name")
      for c in rows {
        print("\(lumText(c))  \("\(c.width)x\(c.height)".pad(11))  \(c.source.pad(16))  \(c.name)")
      }
    }
    print("\(rows.count) candidates")
  }

  private func lumText(_ c: Candidate) -> String {
    c.palette.map { String(format: "%.2f", $0.luminance) } ?? " -- "
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
    for (s, n) in counts.sorted(by: { $0.key < $1.key }) { print("\(s.pad(18)) \(n)") }
    print("\(index.candidates.count) candidates -> \(Index.fileURL.path)")
  }
}
