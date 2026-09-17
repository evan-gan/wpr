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
      var index = Index()
      try index.scan()
      try index.save()
      return index
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Index.self, from: Data(contentsOf: fileURL))
  }

  // older index files predate manualSets
  private enum CodingKeys: String, CodingKey { case candidates, manualSets }
  init() {}
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    candidates = try container.decode([String: Candidate].self, forKey: .candidates)
    manualSets = try container.decodeIfPresent([String: Date].self, forKey: .manualSets) ?? [:]
  }

  func save() throws {
    try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
  }

  // walks the library and generated dirs; new files get measured, missing ones are dropped,
  // existing entries keep their show history
  mutating func scan(verbose: Bool = false) throws {
    let configuration = try Root.config()
    let fileManager = FileManager.default
    var seen = Set<String>()

    let roots: [(Candidate.Kind, URL)] = [(.library, configuration.libraryURL), (.generated, configuration.generatedURL)]
    for (kind, root) in roots {
      let rootPath = root.standardizedFileURL.path
      guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in walker {
        guard ImageInfo.extensions.contains(url.pathExtension.lowercased()) else { continue }
        let path = url.standardizedFileURL.path
        seen.insert(path)
        if candidates[path] != nil { continue }
        guard let (width, height) = ImageInfo.dimensions(url) else {
          if verbose { print("skip (unreadable) \(path)") }
          continue
        }
        var candidate = Candidate(path: path, source: "", kind: kind, width: width, height: height, indexedAt: Date())
        switch kind {
        case .library:
          let parts = path.dropFirst(rootPath.count + 1).split(separator: "/")
          candidate.source = parts.count > 1 ? String(parts[0]) : "misc"
        case .generated:
          let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
          if parts.count >= 3, let seed = UInt32(parts[parts.count - 2]) {
            candidate.module = parts.dropLast(2).joined(separator: "-")
            candidate.seed = seed
          }
          candidate.source = candidate.module ?? "generated"
        }
        candidate.palette = ImageInfo.palette(url)
        candidates[path] = candidate
        if verbose { print("indexed \(candidate.source)/\(candidate.name) \(width)x\(height)") }
      }
    }
    for key in candidates.keys where !seen.contains(key) { candidates.removeValue(forKey: key) }
  }

  mutating func add(generated url: URL, module: Module, seed: UInt32, width: Int, height: Int) {
    let path = url.standardizedFileURL.path
    var candidate = Candidate(path: path, source: module.name, kind: .generated, width: width, height: height, indexedAt: Date())
    candidate.module = module.name
    candidate.seed = seed
    candidate.palette = ImageInfo.palette(url)
    candidates[path] = candidate
  }

  mutating func markShown(_ path: String) {
    candidates[path]?.lastShown = Date()
    candidates[path]?.shownCount += 1
  }

  mutating func markManual(_ screen: Screen) {
    manualSets[screen.uuid] = Date()
  }

  func heldUntil(_ screen: Screen, hold: TimeInterval) -> Date? {
    guard let setAt = manualSets[screen.uuid] else { return nil }
    let until = setAt.addingTimeInterval(hold)
    return until > Date() ? until : nil
  }
}

enum ImageInfo {
  static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "webp"]

  static func dimensions(_ url: URL) -> (Int, Int)? {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
    return orientation >= 5 ? (height, width) : (width, height)
  }

  // 64px thumbnail -> mean luminance/saturation/warmth plus the 5 most common colors (4 bits/channel buckets)
  static func palette(_ url: URL) -> Palette? {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 64,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
    let width = thumbnail.width, height = thumbnail.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
    context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))

    var luminance = 0.0, saturation = 0.0, warmth = 0.0
    var buckets: [UInt16: (count: Int, red: Int, green: Int, blue: Int)] = [:]
    let pixelCount = width * height
    for pixel in 0..<pixelCount {
      let red = Int(pixels[pixel * 4]), green = Int(pixels[pixel * 4 + 1]), blue = Int(pixels[pixel * 4 + 2])
      let brightest = max(red, green, blue), darkest = min(red, green, blue)
      luminance += (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
      saturation += brightest == 0 ? 0 : Double(brightest - darkest) / Double(brightest)
      warmth += Double(red - blue) / 255
      let key = UInt16((red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4))
      var bucket = buckets[key] ?? (0, 0, 0, 0)
      bucket.count += 1; bucket.red += red; bucket.green += green; bucket.blue += blue
      buckets[key] = bucket
    }
    let dominant = buckets.values.sorted { $0.count > $1.count }.prefix(5).map { bucket in
      String(format: "#%02x%02x%02x", bucket.red / bucket.count, bucket.green / bucket.count, bucket.blue / bucket.count)
    }
    return Palette(dominant: dominant, luminance: luminance / Double(pixelCount), saturation: saturation / Double(pixelCount), warmth: warmth / Double(pixelCount))
  }
}
