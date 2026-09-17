import AppKit
import ArgumentParser

struct Screen {
  let index: Int
  let nsScreen: NSScreen

  var name: String { nsScreen.localizedName }
  var scale: CGFloat { nsScreen.backingScaleFactor }
  var isMain: Bool { nsScreen == NSScreen.main }
  var aspect: Double { nsScreen.frame.width / nsScreen.frame.height }

  var pointSize: (w: Int, h: Int) {
    (Int(nsScreen.frame.width), Int(nsScreen.frame.height))
  }

  var pixelSize: (w: Int, h: Int) {
    (Int(nsScreen.frame.width * scale), Int(nsScreen.frame.height * scale))
  }

  var displayID: CGDirectDisplayID {
    nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
  }

  var uuid: String {
    guard let ref = CGDisplayCreateUUIDFromDisplayID(displayID) else { return "?" }
    return CFUUIDCreateString(nil, ref.takeRetainedValue()) as String
  }

  var currentWallpaper: URL? { NSWorkspace.shared.desktopImageURL(for: nsScreen) }
  var currentOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
    NSWorkspace.shared.desktopImageOptions(for: nsScreen) ?? [:]
  }

  static var all: [Screen] {
    NSScreen.screens.enumerated().map { Screen(index: $0.offset + 1, nsScreen: $0.element) }
  }

  static func select(_ spec: String?) throws -> [Screen] {
    guard let spec, spec != "all" else { return all }
    if let i = Int(spec), let s = all.first(where: { $0.index == i }) { return [s] }
    let byName = all.filter { $0.name.localizedCaseInsensitiveContains(spec) }
    if !byName.isEmpty { return byName }
    throw ValidationError("no display matching '\(spec)' (have: \(all.map { "\($0.index)=\($0.name)" }.joined(separator: ", ")))")
  }
}

enum Fill: String, ExpressibleByArgument, CaseIterable {
  case crop, fit, stretch, center

  var options: [NSWorkspace.DesktopImageOptionKey: Any] {
    switch self {
    case .crop: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
    case .fit: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: false]
    case .stretch: [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue]
    case .center: [.imageScaling: NSImageScaling.scaleNone.rawValue]
    }
  }

  static func describe(_ o: [NSWorkspace.DesktopImageOptionKey: Any]) -> String {
    let scaling = (o[.imageScaling] as? UInt).flatMap(NSImageScaling.init(rawValue:))
    let clip = o[.allowClipping] as? Bool ?? false
    switch (scaling, clip) {
    case (.scaleProportionallyUpOrDown, true): return "crop"
    case (.scaleProportionallyUpOrDown, false): return "fit"
    case (.scaleAxesIndependently, _): return "stretch"
    case (.scaleNone, _): return "center"
    default: return "default"
    }
  }
}
