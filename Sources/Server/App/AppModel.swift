import Foundation
import SwiftUI
import GalleyCoreKit
import OSLog
import UserNotifications

private let defaultsLog = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

/// App-wide state for the Server. Port, processor, and template come
/// from the `net.leuski.galley` suite — the same plist the Viewer
/// writes via its standard domain — so picks made in either app
/// surface in the other. `limitToInstance: false` widens the local
/// observer to react to any UserDefaults change in this process;
/// cross-process change signaling is handled separately by
/// `DefaultsBroadcast` (Darwin notification) because
/// `UserDefaults.didChangeNotification` is process-local.
@ObservableDefaults(
  suiteName: "net.leuski.galley",
  limitToInstance: false)
final class Defaults: GalleyRenderDefaults,
                      HTTPServerDefaults,
                      BroadcastedDefaults,
                      GalleyEditorDefaults
{
  var renderer: ProcessorChoice.PersistentSelectionRepresentation?
  var template: TemplateChoice.PersistentSelectionRepresentation?
#if os(macOS)
  var editor: EditorPolicy.PersistentSelectionRepresentation?
  var editorOtherApplicationPath: String?
  var editorCustomURL = InvocationStyle.defaultCustomURL
#endif
  var serverGalleyHash: String?
  /// OS-assigned port the running Server bound to, published here so
  /// Viewer and Quicklook can compose the loopback URL via
  /// `serverEndpointURL`. 0 means "no listener published" (Server
  /// stopped or failed). Written by this process only; everyone else
  /// reads.
  var serverHTTPPort: UInt16 = 0

  @MainActor static let shared = Defaults()

  let broadcaster = DefaultsBroadcast(suiteName: GalleyConstants.suiteName)
}

#if os(macOS)
extension EditorStore {
  static let shared = EditorStore(Defaults.shared)
}
#endif

@MainActor @Observable
final class AppModel {

  // MARK: - In-memory state

  @ObservationIgnored let kosmos: ServerKosmosService

  static let shared = AppModel()

  private init() {
    Self.logInit(
      bundle: Bundle.main.bundleIdentifier,
      renderer: Defaults.shared.renderer,
      template: Defaults.shared.template)

    SingleProcessInstance.enforceSingleInstance()
    Task { @MainActor in
      await ProcessorStore.shared.discover()
    }

    let previewService = PreviewRequestService(
      selectedTemplate: { @MainActor in
        TemplateStore.shared.anyTemplate(forID: Defaults.shared.template?.id)
      },
      renderer: { @MainActor in
        ProcessorStore.shared
          .anyProcessor(forID: Defaults.shared.renderer?.id).renderer
      })

    /// File watcher feeding the SSE live-reload of **both** the optional
    /// HTTP listener and the Kosmos tunnel responder — one watch, shared.
    let watcher = DocumentWatcher()
    self.kosmos = ServerKosmosService(
      service: previewService, watcher: watcher)

    // Bidirectional sync with the shared `net.leuski.galley.shared`
    // suite. Outbound: menu-bar picks here surface in the Viewer
    // process. Inbound: Viewer Settings picks here update the
    // Server's request-time renderer/template providers.
    // See the same block in `Sources/Viewer/Models/AppModel.swift`
    // for the rationale: `UserDefaults.didChangeNotification` is
    // process-local; the Darwin-notification bridge is what makes
    // cross-process change observation actually work.
    Defaults.shared.startListening()

    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        Self.logDidChange(
          renderer: Defaults.shared.renderer,
          template: Defaults.shared.template)
      }
    }

    startServer(service: previewService, watcher: watcher)
    publishGalleyAppHash()
  }

  /// Compute the SHA256 of the Galley.app bundle that contains this
  /// Server.app and write it to the shared suite. The Viewer reads
  /// this on its launch and compares with its own hash; on mismatch
  /// it terminates and relaunches us so a stale Server doesn't
  /// clobber the Viewer's choices through the bindPersistent
  /// round-trip. (Server.app lives at
  /// `<Galley.app>/Contents/Resources/Galley Server.app`, so the
  /// containing app bundle is three levels up.)
  private func publishGalleyAppHash() {
    let serverBundle = Bundle.main.bundleURL
    let galleyApp = serverBundle.parent.parent.parent
    Task.detached(priority: .userInitiated) {
      do {
        let hash = try await galleyApp.computeHash()
        await MainActor.run {
          Defaults.shared.serverGalleyHash = hash
          Defaults.shared.post()
        }
      } catch {
        defaultsLog.error("""
          Server publishGalleyAppHash failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
  }

  private static func notify(
    _ kind: UNUserNotificationCenter.Kind, _ name: String)
  {
    UNUserNotificationCenter.post(kind: kind, displaced: name)
  }

  private static func logInit(
    bundle: String?, renderer: Any?, template: Any?
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    defaultsLog.notice("""
      Server AppModel init pid=\(pid) \
      bundle=\(bundle ?? "?", privacy: .public) \
      renderer=\(String(describing: renderer), privacy: .public) \
      template=\(String(describing: template), privacy: .public)
      """)
  }

  private static func logDidChange(
    renderer: Any?, template: Any?
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    defaultsLog.debug("""
      Server didChange pid=\(pid) \
      renderer=\(String(describing: renderer), privacy: .public) \
      template=\(String(describing: template), privacy: .public)
      """)
  }

  private func startServer(
    service: PreviewRequestService, watcher: DocumentWatcher)
  {
    // The HTTP server is an optional component: present → Quick Look /
    // browsers fetch over loopback; absent → Quick Look renders
    // in-process. Resolved by ObjC-runtime name, so no import here.

    // The Kosmos tunnel renders in-process, so the mesh must come up
    // whether or not the optional HTTP listener exists. With no
    // listener, start Kosmos now (no URL to advertise) and leave
    // `serverHTTPPort` at 0 — Quick Look then renders in-process.
    guard let http = discoverPreviewHTTPListener() else {
      kosmos.start()
      return
    }

    http.start(
      service: service, watcher: watcher,
      host: GalleyConstants.defaultHost)

    // One observer covers three responsibilities, since `stateChanges`
    // is single-consumer:
    //
    // 1. Mirror the state into `httpState` / `httpURL` for the menu bar.
    // 2. Publish the bound port to the shared `net.leuski.galley`
    //    defaults on every transition. Quicklook composes the loopback
    //    URL through `Defaults.shared.serverEndpointURL`; 0 = no listener.
    // 3. Start Kosmos exactly once, on the first `.running` / `.failed`,
    //    advertising the loopback URL so Mac Viewer's pill can show the
    //    port. `.failed` still starts Kosmos so peers see liveness.
    Task { [weak self, kosmos] in
      var kosmosStarted = false
      for await state in http.stateChanges {
        guard self != nil else { return }
        switch state {
        case .running(let url):
          let port = (url.port).flatMap { UInt16(exactly: $0) } ?? 0
          Defaults.shared.serverHTTPPort = port
          Defaults.shared.post()
          if !kosmosStarted {
            kosmos.start()
            kosmosStarted = true
          }
        case .failed:
          Defaults.shared.serverHTTPPort = 0
          Defaults.shared.post()
          if !kosmosStarted {
            kosmos.start()
            kosmosStarted = true
          }
        case .stopped:
          Defaults.shared.serverHTTPPort = 0
          Defaults.shared.post()
        }
      }
    }
  }
}
