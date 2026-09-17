import Foundation
import CoreGraphics
import ImageIO

struct Palette: Codable {
  var dominant: [String]
  var luminance: Double
  var saturation: Double
  var warmth: Double
}

struct Candidate: Codable {
  enum Kind: String, Codable { case library, generated }

  var path: String
  var source: String
  var kind: Kind
  var width: Int
  var height: Int
  var module: String?
  var seed: UInt32?
  var palette: Palette?
  var indexedAt: Date
  var lastShown: Date?
  var shownCount = 0

  var url: URL { URL(fileURLWithPath: path) }
  var aspect: Double { Double(width) / Double(height) }
  var name: String { url.lastPathComponent }
}

struct Index: Codable {
  var candidates: [String: Candidate] = [:]
  // display uuid -> when a human last set its wallpaper; tick leaves those alone for rotation.hold_manual
  var manualSets: [String: Date] = [:]

  static var fileURL: URL { Root.dataDirectory.appending(path: "index.json") }

  static func load() throws -> Index {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      var idx = Index()
      try idx.scan()
      try idx.save()
      return idx
    }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try dec.decode(Index.self, from: Data(contentsOf: fileURL))
  }

  // older index files predate manualSets
  private enum CodingKeys: String, CodingKey { case candidates, manualSets }
  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    candidates = try c.decode([String: Candidate].self, forKey: .candidates)
    manualSets = try c.decodeIfPresent([String: Date].self, forKey: .manualSets) ?? [:]
  }

  func save() throws {
    try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(self).write(to: Self.fileURL, options: .atomic)
  }

  // walks the library and generated dirs; new files get measured, missing ones are dropped,
  // existing entries keep their show history
  mutating func scan(verbose: Bool = false) throws {
    let cfg = try Root.config()
    let fm = FileManager.default
    var seen = Set<String>()

    let roots: [(Candidate.Kind, URL)] = [(.library, cfg.libraryURL), (.generated, cfg.generatedURL)]
    for (kind, root) in roots {
      let rootPath = root.standardizedFileURL.path
      guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in walker {
        guard ImageInfo.extensions.contains(url.pathExtension.lowercased()) else { continue }
        let path = url.standardizedFileURL.path
        seen.insert(path)
        if candidates[path] != nil { continue }
        guard let (w, h) = ImageInfo.dimensions(url) else {
          if verbose { print("skip (unreadable) \(path)") }
          continue
        }
        var c = Candidate(path: path, source: "", kind: kind, width: w, height: h, indexedAt: Date())
        switch kind {
        case .library:
          let parts = path.dropFirst(rootPath.count + 1).split(separator: "/")
          c.source = parts.count > 1 ? String(parts[0]) : "misc"
        case .generated:
          let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
          if parts.count >= 3, let seed = UInt32(parts[parts.count - 2]) {
            c.module = parts.dropLast(2).joined(separator: "-")
            c.seed = seed
          }
          c.source = c.module ?? "generated"
        }
        c.palette = ImageInfo.palette(url)
        candidates[path] = c
        if verbose { print("indexed \(c.source)/\(c.name) \(w)x\(h)") }
      }
    }
    for k in candidates.keys where !seen.contains(k) { candidates.removeValue(forKey: k) }
  }

  mutating func add(generated url: URL, module: Module, seed: UInt32, width: Int, height: Int) {
    let path = url.standardizedFileURL.path
    var c = Candidate(path: path, source: module.name, kind: .generated, width: width, height: height, indexedAt: Date())
    c.module = module.name
    c.seed = seed
    c.palette = ImageInfo.palette(url)
    candidates[path] = c
  }

  mutating func markShown(_ path: String) {
    candidates[path]?.lastShown = Date()
    candidates[path]?.shownCount += 1
  }

  mutating func markManual(_ screen: Screen) {
    manualSets[screen.uuid] = Date()
  }

  func heldUntil(_ screen: Screen, hold: TimeInterval) -> Date? {
    guard let t = manualSets[screen.uuid] else { return nil }
    let until = t.addingTimeInterval(hold)
    return until > Date() ? until : nil
  }
}

enum ImageInfo {
  static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "webp"]

  static func dimensions(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
    return orientation >= 5 ? (h, w) : (w, h)
  }

  // 64px thumbnail -> mean luminance/saturation/warmth plus the 5 most common colors (4 bits/channel buckets)
  static func palette(_ url: URL) -> Palette? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 64,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let w = thumb.width, h = thumb.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
    ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))

    var lum = 0.0, sat = 0.0, warm = 0.0
    var buckets: [UInt16: (count: Int, r: Int, g: Int, b: Int)] = [:]
    let n = w * h
    for i in 0..<n {
      let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
      let mx = max(r, g, b), mn = min(r, g, b)
      lum += (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
      sat += mx == 0 ? 0 : Double(mx - mn) / Double(mx)
      warm += Double(r - b) / 255
      let key = UInt16((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4))
      var bk = buckets[key] ?? (0, 0, 0, 0)
      bk.count += 1; bk.r += r; bk.g += g; bk.b += b
      buckets[key] = bk
    }
    let dominant = buckets.values.sorted { $0.count > $1.count }.prefix(5).map { bk in
      String(format: "#%02x%02x%02x", bk.r / bk.count, bk.g / bk.count, bk.b / bk.count)
    }
    return Palette(dominant: dominant, luminance: lum / Double(n), saturation: sat / Double(n), warmth: warm / Double(n))
  }
}

extension String {
  func pad(_ n: Int) -> String {
    count >= n ? self : self + String(repeating: " ", count: n - count)
  }
}
