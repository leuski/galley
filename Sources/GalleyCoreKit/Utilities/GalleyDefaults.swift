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

extension GalleyRenderDefaults {
  @MainActor public var resolvedTemplate: Template {
    TemplateStore.shared.anyTemplate(forID: template?.id)
  }
  @MainActor public var resolvedRenderer: any MarkdownRenderer {
    ProcessorStore.shared.anyProcessor(forID: renderer?.id).renderer
    ?? SwiftMarkdownRenderer()
  }
}

public protocol GalleyEditorDefaults: GalleyDefaults {
#if os(macOS)
  var editor: EditorPolicy.PersistentSelectionRepresentation? { get set }
  var editorOtherApplicationPath: String? { get set }
  var editorCustomURL: String { get set }
#endif
}

#if os(macOS)
extension GalleyEditorDefaults {
  public var editorOtherApplication: URL? {
    get { editorOtherApplicationPath.flatMap { URL(string: $0) } }
    set { editorOtherApplicationPath = newValue?.absoluteString }
  }
}
#endif

public protocol GalleyKosmosDefaults: GalleyDefaults {
  /// OS-assigned TCP port the running Server's Kosmos link bound to,
  /// paired with `serverKosmosDeviceID`. Published here so a same-Mac
  /// Viewer can eager-dial the Kosmos mesh (seed peer) instead of
  /// waiting on Bonjour browse+resolve. 0 means "not published"
  /// (Server stopped / link not up). Written by this process only.
  var serverKosmosPort: UInt16 { get set }
  /// The running Server's Kosmos `deviceID` (UUID string), paired with
  /// `serverKosmosPort`. Lets the Viewer key the seed peer up front so
  /// the eager dial and a later Bonjour discovery of the same Server
  /// don't form two sessions. `nil` when no link is published.
  var serverKosmosDeviceID: DeviceID? { get set }
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
