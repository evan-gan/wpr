import IOKit.ps

public enum Power {
  // a machine with no battery reports no providing source; treat that as AC
  public static func isOnAC() -> Bool {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
    return (type as String) == kIOPMACPowerKey
  }
}
