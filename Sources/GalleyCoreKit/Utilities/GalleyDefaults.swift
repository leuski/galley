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
  @MainActor static var shared: Self { get }
}

public protocol GalleyNetworkDefaults: GalleyDefaults {
  var port: UInt16 { get set }
}

public protocol GalleyRenderDefaults: GalleyDefaults {
  var renderer: String? { get set }
  var template: String? { get set }
}

public let bundleIdentifier = Bundle.main.bundleIdentifier
?? GalleyConstants.suiteName

public enum GalleyConstants {
  public static let defaultHost: String = "127.0.0.1"
  public static let defaultPort: UInt16 = 8089
  public static let settingsURL: URL = "galley://settings"

  /// Build a `galley://settings` URL aimed at a specific Settings tab.
  /// `nil` returns the bare `settingsURL` (no tab preference).
  public static func settingsURL(tab: SettingsTab?) -> URL {
    guard let tab else { return settingsURL }
    var components = URLComponents()
    components.scheme = "galley"
    components.host = "settings"
    components.queryItems = [URLQueryItem(name: "tab", value: tab.rawValue)]
    guard let url = components.url else {
      preconditionFailure("settingsURL components produced no URL")
    }
    return url
  }

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

public extension GalleyNetworkDefaults {
  var host: URL {
    hostURL(port: port)
  }
}
