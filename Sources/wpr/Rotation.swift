import Foundation

enum Fit {
  // fraction of the image's area that survives a center-crop onto the display
  static func score(imageAspect: Double, displayAspect: Double) -> Double {
    min(imageAspect / displayAspect, displayAspect / imageAspect)
  }

  // 1.0 when the image has at least the display's pixels on both axes; below that it'll be upscaled
  static func resolution(_ candidate: Candidate, _ screen: Screen) -> Double {
    min(1.0, Double(candidate.width) / Double(screen.pixelSize.w), Double(candidate.height) / Double(screen.pixelSize.h))
  }

  // generated images were rendered for one exact display; never crop them onto another
  static func sizeAllowed(_ candidate: Candidate, _ screen: Screen) -> Bool {
    candidate.kind != .generated || (candidate.width == screen.pixelSize.w && candidate.height == screen.pixelSize.h)
  }
}

struct Picker {
  let configuration: Config
  let index: Index

  struct Entry { let candidate: Candidate; let fit: Double; let resolution: Double }

  func eligible(for screen: Screen, source: String?) -> [Entry] {
    index.candidates.values.compactMap { candidate in
      guard configuration.sources.enabled.contains(candidate.source) else { return nil }
      if let source, candidate.source != source { return nil }
      guard Fit.sizeAllowed(candidate, screen) else { return nil }
      let fit = Fit.score(imageAspect: candidate.aspect, displayAspect: screen.aspect)
      let resolution = Fit.resolution(candidate, screen)
      guard fit >= configuration.rotation.minFit, resolution >= configuration.rotation.minRes else { return nil }
      return Entry(candidate: candidate, fit: fit, resolution: resolution)
    }
  }

  // two stages: pick a source (weighted by sqrt of its eligible count, so big folders don't drown
  // small ones), then an image within it favoring fit, resolution, and not-recently-shown
  func pick(for screen: Screen, source: String?, avoiding: Set<String>) -> Entry? {
    let pool = eligible(for: screen, source: source).filter { !avoiding.contains($0.candidate.path) }
    guard !pool.isEmpty else { return nil }
    let bySource = Dictionary(grouping: pool, by: \.candidate.source)
    let sources = Array(bySource.keys)
    guard let chosen = weighted(sources, sources.map { Double(bySource[$0]!.count).squareRoot() }) else { return nil }
    let group = bySource[chosen]!
    let now = Date()
    let dark: Bool? = configuration.rotation.matchAppearance ? Appearance.isDark : nil
    let weights = group.map { entry -> Double in
      let recency = entry.candidate.lastShown.map { min(1.0, now.timeIntervalSince($0) / 86400) } ?? 1.0
      var weight = entry.fit * (0.5 + 0.5 * entry.resolution) * (0.15 + 0.85 * recency)
      if let dark, let luminance = entry.candidate.palette?.luminance {
        weight *= 0.05 + 0.95 * Appearance.preference(luminance: luminance, dark: dark)
      }
      return weight
    }
    return weighted(group, weights)
  }

  private func weighted<T>(_ items: [T], _ weights: [Double]) -> T? {
    guard !items.isEmpty else { return nil }
    var remaining = Double.random(in: 0..<weights.reduce(0, +))
    for (item, weight) in zip(items, weights) {
      remaining -= weight
      if remaining <= 0 { return item }
    }
    return items.last
  }
}
