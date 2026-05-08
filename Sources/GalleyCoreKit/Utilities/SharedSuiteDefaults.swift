import Foundation

/// Cross-process accessor for the shared `net.leuski.galley` plist.
/// The Viewer's bundle id *is* the suite name, so
/// `UserDefaults(suiteName:)` returns nil there and the standard
/// domain (which already maps to the same plist) has to be used
/// instead. The Server reaches the same plist via the explicit
/// suite. `suite` collapses both into one accessor so cross-process
/// keys (like the Galley-app hash the Server publishes for the
/// Viewer to read on launch) can be touched the same way from
/// either app.
public enum SharedSuiteDefaults {
  /// UserDefaults instance pointing at the shared
  /// `net.leuski.galley` plist regardless of which process is the
  /// caller.
  public static var suite: UserDefaults {
    if Bundle.main.bundleIdentifier == GalleyConstants.suiteName {
      return .standard
    }
    return UserDefaults(suiteName: GalleyConstants.suiteName) ?? .standard
  }

  /// Hash of the Galley.app bundle the Server saw at its launch.
  /// Read by the Viewer on its launch to detect a stale Server.
  public static let serverGalleyHashKey = "serverGalleyHash"
}
