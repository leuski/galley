import AppKit
import GalleyCoreKit
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "ServerAppDelegate")

/// File-open dispatch for Galley Server.
///
/// When the Server receives a file (via the system default-handler
/// mechanism, the Viewer's "Show on Vision Pro" command, or a script
/// that calls `NSWorkspace.open(_:withApplicationAt:)`), it decides
/// where the file should actually surface:
///
/// - If a Kosmos peer is connected, publish `OpenURL` over Kosmos so
///   AVP opens the file.
/// - Otherwise, hand the file off to `Galley.app` (the host viewer)
///   via `NSWorkspace.open(_:withApplicationAt:)`. Galley.app stays
///   the local UI; Server stays a headless bridge.
///
/// `AppBoot` is the boot wrapper that owns the `AppModel`; we hold a
/// weak reference to it so the delegate can ask for the current
/// `ServerKosmosService` whenever a file shows up.
@MainActor
final class ServerAppDelegate: NSObject, NSApplicationDelegate {
  weak var boot: AppBoot?

  func application(_ application: NSApplication, open urls: [URL]) {
    // URLs arrive in two shapes: real `file://` URLs from
    // LaunchServices when the Server is the document-type handler,
    // and `galley-bridge://<path>` URLs from Galley.app's
    // "Show on Vision Pro" command (see `BridgeURL`). Normalize both
    // to file URLs before dispatching.
    let fileURLs = urls.compactMap { url -> GalleyBridgeRequest? in
      if url.isFileURL { return GalleyBridgeRequest(target: .init(url: url)) }
      if let bridged = GalleyBridgeRequest(from: url) { return bridged }
      log.error("""
        Ignoring open request with unrecognized URL scheme: \
        \(url.absoluteString, privacy: .public)
        """)
      return nil
    }
    log.notice("""
      application(_:open:) received=\(urls.count, privacy: .public) \
      resolved=\(fileURLs.count, privacy: .public)
      """)
    guard let boot, let model = boot.model else {
      log.notice("""
        Boot not ready. Falling back to local Galley.app for \
        \(fileURLs.count, privacy: .public) file(s).
        """)
      for fileURL in fileURLs {
        ServerKosmosService.openInLocalGalleyApp(fileURL)
      }
      return
    }
    Task {
      for fileURL in fileURLs {
        await ServerKosmosService.dispatchOpenURL(fileURL, with: model.kosmos)
      }
    }
  }
}
