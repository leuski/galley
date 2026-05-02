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
  var enablePerDocumentOverrides: Bool { get set }
  @MainActor static var shared: Self { get }
}

public enum GalleyConstants {
  public static let defaultPort: UInt16 = 8089
  public static let settingsURL: URL = "galley://settings"
}
