import IOKit.ps

enum Power {
  // a machine with no battery reports no providing source; treat that as AC
  static func isOnAC() -> Bool {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
    return (type as String) == kIOPMACPowerKey
  }
}
