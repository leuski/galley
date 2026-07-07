import Foundation

/// Shared defaults contract between the Viewer and Server apps.
/// Both AppModels conform to this protocol. The Viewer backs it with
/// its standard domain (its bundle id is `net.leuski.galley`, so
/// `UserDefaults(suiteName:)` refuses that name); the Server opens
/// the same plist via `UserDefaults(suiteName: "net.leuski.galley")`.
/// Cross-process change observation is provided by
/// `DefaultsBroadcast` (Darwin notification), not by `cfprefsd`
/// notifications — `UserDefaults.didChangeNotification` is
/// process-local.
public protocol GalleyDefaults: DefaultsProtocol
{
}

extension GalleyDefaults {
  var suiteName: String { GalleyConstants.suiteName }
}

public protocol GalleyRenderDefaults: GalleyDefaults {
  var renderer: ProcessorChoice.PersistentSelectionRepresentation? { get set }
  var template: TemplateChoice.PersistentSelectionRepresentation?
  { get set }
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
    URL.localizedApplicationSupportDirectory(suiteName)
  }
}
