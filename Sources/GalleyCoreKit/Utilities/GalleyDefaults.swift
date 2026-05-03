import Foundation
@_exported import ObservableDefaults
import ALFoundation

/// Shared defaults contract between the Viewer and Server apps.
/// Both AppModels conform to this protocol and back its properties
/// with `@ObservableDefaults(suiteName: GalleyDefaults.suiteName)`.
/// The suite maps to `~/Library/Preferences/net.leuski.galley.plist`,
/// the same file as the Viewer's standard domain, so cross-process
/// reads from the Server require no sandbox entitlements.
public protocol GalleyDefaults: AnyObject {
  var port: UInt16 { get set }
  var rendererPersistent: String? { get set }
  var templatePersistent: String? { get set }
  @MainActor static var shared: Self { get }
}

public enum GalleyConstants {
  public static let defaultHost: String = "127.0.0.1"
  public static let defaultPort: UInt16 = 8089
  public static let settingsURL: URL = "galley://settings"

  /// Bundle id of the Viewer app, which doubles as the shared
  /// `UserDefaults` suite name and the shared Application Support
  /// folder name. The Server reads/writes the same plist and the same
  /// `Templates/` directory so picks made in either app survive a
  /// process boundary.
  public static let suiteName: String = "net.leuski.galley"

  /// Shared `~/Library/Application Support/net.leuski.galley/`. Used
  /// by both apps so user-defined templates and any other shared
  /// on-disk state live in one place regardless of which process is
  /// running.
  public static var applicationSupportDirectory: URL {
    URL.applicationSupportDirectory / suiteName
  }
}

nonisolated private func hostURL(port: UInt16) -> URL {
  var components = URLComponents()
  components.scheme = "http"
  components.host = GalleyConstants.defaultHost
  components.port = Int(port)
  guard let url = components.url else {
    preconditionFailure("hostURL components produced no URL")
  }
  return url
}

public extension GalleyDefaults {
  var host: URL {
    hostURL(port: port)
  }
}
