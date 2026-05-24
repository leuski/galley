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

public protocol GalleyRenderDefaults: GalleyDefaults {
  var renderer: String? { get set }
  var template: String? { get set }
}

/// Live HTTP listener coordinates for the Galley Server, published
/// through the shared `net.leuski.galley` plist so cross-process
/// readers (Server, Viewer, Quicklook) all see the same value.
/// The Server is the sole writer; it sets `serverHTTPPort` to the
/// OS-assigned port on bind, and back to 0 on stop or failure.
public protocol GalleyNetworkDefaults: GalleyDefaults {
  var serverHTTPPort: UInt16 { get set }
}

public extension GalleyNetworkDefaults {
  /// `http://127.0.0.1:<port>/` for the running Server, or nil when
  /// no port is published (port == 0). Loopback-only — AVP doesn't
  /// dial this; it tunnels through Kosmos. All same-machine consumers
  /// reach the listener here.
  var serverEndpointURL: URL? {
    guard serverHTTPPort != 0 else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = GalleyConstants.defaultHost
    components.port = Int(serverHTTPPort)
    return components.url
  }
}

public let bundleIdentifier = Bundle.main.bundleIdentifier
?? GalleyConstants.suiteName

public enum GalleyConstants {
  public static let defaultHost = "127.0.0.1"

  /// Bundle id of the Viewer app, which doubles as the shared
  /// `UserDefaults` suite identifier (the Server opens it explicitly,
  /// the Viewer reaches it as `.standard`) and the shared Application
  /// Support folder name.
  public static let suiteName = "net.leuski.galley"

  /// Shared `~/Library/Application Support/net.leuski.galley/`. Used
  /// by both apps so user-defined templates and any other shared
  /// on-disk state live in one place regardless of which process is
  /// running.
  public static var applicationSupportDirectory: URL {
    URL.applicationSupportDirectory / "\(suiteName).localized"
  }
}
