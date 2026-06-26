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
                      BroadcastedDefaults
{
  var renderer: String?
  var template: String?
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

@MainActor @Observable
final class AppModel {

  // MARK: - In-memory state

  let templates: TemplateChoice
  let processors: ProcessorChoice

  /// File watcher feeding the SSE live-reload of **both** the optional
  /// HTTP listener and the Kosmos tunnel responder — one watch, shared.
  @ObservationIgnored let watcher = DocumentWatcher()
  /// Request-time render config (selected template + renderer), read by
  /// both the optional HTTP listener and the tunnel responder.
  @ObservationIgnored let previewService: PreviewRequestService
  /// The optional loopback HTTP preview server (`GalleyServerKit`),
  /// resolved at runtime. `nil` → no HTTP listener; Quick Look renders
  /// in-process. Nothing here imports `GalleyServerKit`.
  @ObservationIgnored let httpListener: (any PreviewHTTPListener)?
  @ObservationIgnored let kosmos: ServerKosmosService

  /// Mirrors the HTTP listener's state for the menu bar. Stays
  /// `.stopped` when the feature is absent (see `httpFeatureAvailable`).
  private(set) var httpState: PreviewHTTPListenerState = .stopped
  /// Loopback base URL once the listener binds; `nil` when the feature
  /// is absent or the listener hasn't bound. Drives the menu's
  /// "Open File…" browser action.
  private(set) var httpURL: URL?
  /// Whether an HTTP listener was discovered at launch.
  var httpFeatureAvailable: Bool { httpListener != nil }

  @ObservationIgnored private var persistenceTokens: [Cancellable] = []

  init() {
    Self.logInit(
      bundle: Bundle.main.bundleIdentifier,
      renderer: Defaults.shared.renderer,
      template: Defaults.shared.template)
    self.templates = TemplateChoice(
      source: TemplateStore.shared,
      persistent: Defaults.shared.template) { name in
        Self.notify(.template, name)
      }

    self.processors = ProcessorChoice(
      source: ProcessorStore.shared,
      persistent: Defaults.shared.renderer) { name in
        Self.notify(.processor, name)
      }

    self.previewService = PreviewRequestService(
      selectedTemplate: { [weak templates] in
        await templates?.selected.value ?? .default
      },
      renderer: { [weak processors] in
        await processors?.selected.value.renderer
      })
    self.kosmos = ServerKosmosService(
      service: self.previewService, watcher: self.watcher)
    // The HTTP server is an optional component: present → Quick Look /
    // browsers fetch over loopback; absent → Quick Look renders
    // in-process. Resolved by ObjC-runtime name, so no import here.
    self.httpListener = discoverPreviewHTTPListener()

    // Bidirectional sync with the shared `net.leuski.galley.shared`
    // suite. Outbound: menu-bar picks here surface in the Viewer
    // process. Inbound: Viewer Settings picks here update the
    // Server's request-time renderer/template providers.
    // See the same block in `Sources/Viewer/Models/AppModel.swift`
    // for the rationale: `UserDefaults.didChangeNotification` is
    // process-local; the Darwin-notification bridge is what makes
    // cross-process change observation actually work.
    Defaults.shared.startListening()

    persistenceTokens = bindPersistent(
      templates,
      label: "Server.template",
      property: \Defaults.template)
    + bindPersistent(
      processors,
      label: "Server.processor",
      property: \Defaults.renderer)

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

    startServer()
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
    bundle: String?, renderer: String?, template: String?
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    defaultsLog.notice("""
      Server AppModel init pid=\(pid) \
      bundle=\(bundle ?? "?", privacy: .public) \
      renderer=\(renderer ?? "nil", privacy: .public) \
      template=\(template ?? "nil", privacy: .public)
      """)
  }

  private static func logDidChange(
    renderer: String?, template: String?
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    defaultsLog.debug("""
      Server didChange pid=\(pid) \
      renderer=\(renderer ?? "nil", privacy: .public) \
      template=\(template ?? "nil", privacy: .public)
      """)
  }

  private func startServer() {
    // The Kosmos tunnel renders in-process, so the mesh must come up
    // whether or not the optional HTTP listener exists. With no
    // listener, start Kosmos now (no URL to advertise) and leave
    // `serverHTTPPort` at 0 — Quick Look then renders in-process.
    guard let http = httpListener else {
      kosmos.start()
      return
    }

    http.start(
      service: previewService, watcher: watcher,
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
        guard let self else { return }
        self.httpState = state
        switch state {
        case .running(let url):
          let port = (url.port).flatMap { UInt16(exactly: $0) } ?? 0
          self.httpURL = url
          Defaults.shared.serverHTTPPort = port
          Defaults.shared.post()
          if !kosmosStarted {
            kosmos.start()
            kosmosStarted = true
          }
        case .failed:
          self.httpURL = nil
          Defaults.shared.serverHTTPPort = 0
          Defaults.shared.post()
          if !kosmosStarted {
            kosmos.start()
            kosmosStarted = true
          }
        case .stopped:
          self.httpURL = nil
          Defaults.shared.serverHTTPPort = 0
          Defaults.shared.post()
        }
      }
    }
  }
}

/// Boot wrapper that runs async processor discovery before
/// constructing the real AppModel. The view tree branches on
/// `model` being non-nil; while loading, a placeholder UI is shown.
@Observable @MainActor
final class AppBoot {
  private(set) var model: AppModel?

  init() {
    SingleProcessInstance.enforceSingleInstance()
    // Notification permission is presented as a system sheet on
    // first run; awaiting it would block boot until the user
    // responds. Fire it in parallel and let it resolve whenever.
    Task { await UNUserNotificationCenter.requestAuthorization() }
    Task { @MainActor in
      await ProcessorStore.shared.discover()
      self.model = AppModel()
    }
  }
}
