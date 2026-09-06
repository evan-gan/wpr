import Foundation

enum Appearance {
  // NSGlobalDomain is in every process's defaults search list; the key is absent in light mode
  static var isDark: Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
  }

  // 1.0 = ideal for the current appearance, 0.0 = clashes. soft ramps, so nothing is excluded outright
  static func preference(luminance: Double, dark: Bool) -> Double {
    let t = dark ? (luminance - 0.25) / 0.35 : (luminance - 0.30) / 0.35
    let ramp = min(1.0, max(0.0, t))
    return dark ? 1.0 - ramp : ramp
  }
}
