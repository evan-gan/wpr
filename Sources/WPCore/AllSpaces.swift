import Foundation

// NSWorkspace can only set the wallpaper for the *current* Space. WallpaperAgent records that choice in
// a private store (macOS 14+), keyed Space -> display. To reach every Space we copy the entry it just
// wrote into each Space, then restart the agent so it rereads the store. Best effort: the format is
// undocumented, so anything unexpected becomes an error rather than a guess.
public enum AllSpaces {
  public static var storeURL: URL {
    URL.libraryDirectory.appending(path: "Application Support/com.apple.wallpaper/Store/Index.plist")
  }

  /// Copy each display's freshly set wallpaper to every Space and reload WallpaperAgent.
  ///
  /// - Parameters:
  ///   - wallpapers: display uuid (as `Screen.uuid`) -> image file just set with NSWorkspace
  ///   - timeout: how long to wait for WallpaperAgent to record the new images, which it does asynchronously
  public static func apply(_ wallpapers: [String: URL], timeout: TimeInterval = 5) throws {
    guard !wallpapers.isEmpty else { return }
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      var store = try readStore()
      let missing = wallpapers.filter { !spread(in: &store, display: $0.key, image: $0.value) }
      if missing.isEmpty {
        try writeStore(store)
        try restartAgent()
        return
      }
      guard Date() < deadline else {
        let names = missing.values.map(\.lastPathComponent).joined(separator: ", ")
        throw WPError("macOS hadn't recorded \(names) in \(storeURL.path) after \(Int(timeout))s, so only the current Space changed. pass --no-all-spaces to skip this step")
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }

  /// Copy the entry showing `image` on `display` into every Space (and the display's fallback entry).
  ///
  /// - Parameters:
  ///   - store: the decoded Index.plist, modified in place
  ///   - display: display uuid
  ///   - image: the image that should now be on that display
  /// - Returns: false if no entry for that display shows `image` yet (the store is left untouched)
  @discardableResult
  public static func spread(in store: inout [String: Any], display: String, image: URL) -> Bool {
    let wanted = image.standardizedFileURL.path
    var spaces = store["Spaces"] as? [String: Any] ?? [:]
    let perSpace = spaces.values.compactMap { (($0 as? [String: Any])?["Displays"] as? [String: Any])?[display] }
    let fallback = (store["Displays"] as? [String: Any])?[display]
    guard let source = (perSpace + [fallback].compactMap { $0 }).first(where: { imagePath(of: $0) == wanted }) else {
      return false
    }

    for (spaceID, value) in spaces {
      var space = value as? [String: Any] ?? [:]
      var displays = space["Displays"] as? [String: Any] ?? [:]
      displays[display] = source
      space["Displays"] = displays
      spaces[spaceID] = space
    }
    store["Spaces"] = spaces
    // new Spaces (and displays with no per-Space entry yet) fall back to this
    var displays = store["Displays"] as? [String: Any] ?? [:]
    displays[display] = source
    store["Displays"] = displays
    return true
  }

  /// The image file a store display entry shows on the desktop, or nil for non-image wallpapers.
  static func imagePath(of entry: Any) -> String? {
    guard let desktop = (entry as? [String: Any])?["Desktop"] as? [String: Any],
          let content = desktop["Content"] as? [String: Any],
          let choice = (content["Choices"] as? [Any])?.first as? [String: Any],
          let configuration = choice["Configuration"] as? Data, !configuration.isEmpty,
          let decoded = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
          let relative = (decoded["url"] as? [String: Any])?["relative"] as? String,
          let url = URL(string: relative), url.isFileURL
    else { return nil }
    return url.standardizedFileURL.path
  }

  static func readStore() throws -> [String: Any] {
    let data: Data
    do {
      data = try Data(contentsOf: storeURL)
    } catch {
      throw WPError("can't read the macOS wallpaper store at \(storeURL.path) (needs macOS 14+): \(error.localizedDescription). pass --no-all-spaces to skip this step")
    }
    guard let store = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      throw WPError("\(storeURL.path) isn't the dictionary wpr expects; macOS may have changed its format. pass --no-all-spaces to skip this step")
    }
    return store
  }

  static func writeStore(_ store: [String: Any]) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    try data.write(to: storeURL, options: .atomic)
  }

  // launchd relaunches it right away, and the fresh process loads the store we just edited
  static func restartAgent() throws {
    let result = try Subprocess.run(executable: "/usr/bin/killall", arguments: ["WallpaperAgent"])
    guard result.status == 0 else {
      throw WPError("couldn't restart WallpaperAgent (\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))); other Spaces keep their old wallpaper until it restarts")
    }
  }
}
