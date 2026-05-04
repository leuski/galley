import Foundation
@_exported import ObservableDefaults
import ALFoundation

/// Shared defaults contract between the Viewer and Server apps.
/// Both AppModels conform to this protocol. The Viewer backs it with
/// its standard domain (its bundle id is `net.leuski.galley`, so
/// `UserDefaults(suiteName:)` refuses that name); the Server opens
/// the same plist via `UserDefaults(suiteName: "net.leuski.galley")`.
/// Cross-process change observation is provided by
/// `DefaultsBroadcast` (Darwin notification), not by `cfprefsd`
/// notifications — `UserDefaults.didChangeNotification` is
/// process-local.
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
  /// `UserDefaults` suite identifier (the Server opens it explicitly,
  /// the Viewer reaches it as `.standard`) and the shared Application
  /// Support folder name.
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
