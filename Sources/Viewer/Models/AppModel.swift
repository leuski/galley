import Foundation
import GalleyCoreKit
import KosmosAppKit
import SwiftUI
import OSLog
import UserNotifications

private let defaultsLog = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

@MainActor @Observable
final class AppModel {
  // MARK: - In-memory state (not persisted by the macro)

  let templates: TemplateChoice
  let processors: ProcessorChoice
  let colorSchemes: ColorSchemeChoice

  @ObservationIgnored private var persistenceTokens: [Cancelable] = []

#if os(macOS)
  @ObservationIgnored let editors: EditorChoice

  /// Tab the Settings scene should display. The bootstrap modifier
  /// writes here when a `galley://settings?tab=<id>` URL arrives, just
  /// before invoking `openSettings()`. `SettingsView` binds its
  /// `TabView` selection to this property so external deep links can
  /// land on the right pane.
  var selectedSettingsTab: SettingsTab = .general
#else
  @ObservationIgnored private var appPhase: ScenePhase?
  @ObservationIgnored private var open: (@MainActor () -> Void)?
#endif

  /// Constructs an already-hydrated AppModel. Caller (`AppBoot`) is
  /// expected to have run async catalog discovery
  /// (`await processorStore.discover()`) before invoking this so the
  /// initial decode lands honestly. Once constructed, processor and
  /// template selections stay in sync with the shared defaults suite
  /// in both directions — Server writes propagate here automatically
  /// via `limitToInstance: false`.
  init() {
    Self.logInit(
      bundle: Bundle.main.bundleIdentifier,
      renderer: Defaults.shared.renderer,
      template: Defaults.shared.template)
#if os(macOS)
    self.editors = EditorChoice()
#endif

//  #if ENABLE_TUNNEL
//      self.scemeHandler = SelectingDotSchemeHandler(
//        local: LocalDotSchemeHandler(catalog: catalog),
//        tunnel: TunnelDotSchemeHandler(tunnel: kosmos.tunnel)).schemeHandler
//      kosmos.start()
//  #else
//      self.scemeHandler = PreviewSchemeHandler().schemeHandler
//  #endif

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

    // Color-scheme catalog is static (`light`/`dark`) so the
    // displacement notifier is a no-op — the catalog can't lose a
    // case at runtime the way templates or processors can.
    self.colorSchemes = ColorSchemeChoice(
      source: ColorSchemeStore.shared,
      persistent: Defaults.shared.colorScheme)

    // Darwin-notification bridge: `UserDefaults.didChangeNotification`
    // is process-local, so the Server (a near-idle menu-bar app) never
    // wakes up to re-read the shared suite when the Viewer writes.
    // `startListening` translates inbound Darwin notifications into a
    // local didChangeNotification post that the ObservableDefaults
    // macro observer is already subscribed to. `post()` after each
    // outbound write fires the cross-process signal.
    Defaults.shared.startListening()

    persistenceTokens = bindPersistent(
      templates,
      label: "Viewer.template",
      property: \Defaults.template)
    + bindPersistent(
      processors,
      label: "Viewer.processor",
      property: \Defaults.renderer)
    + bindPersistent(
      colorSchemes,
      label: "Viewer.colorScheme",
      property: \Defaults.colorScheme)

    // Log every ObservableDefaults notification arriving in this
    // process — that's the signal bindPersistent's inbound side
    // listens to. If this fires but the choice doesn't update,
    // the gap is in bindPersistent or downstream observation.
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
      Viewer AppModel init pid=\(pid) \
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
      Viewer didChange pid=\(pid) \
      renderer=\(renderer ?? "nil", privacy: .public) \
      template=\(template ?? "nil", privacy: .public)
      """)
  }

#if os(visionOS)
  func didDismissWindow(url: URL?) {
    defaultsLog.notice("""
      didDismissWindow \
      \(url?.absoluteString ?? "nil", privacy: .public)
      """)
    if url != nil, appPhase == .background {
      open?()
    }
  }

  func didChangePhase(
    scenePhase: ScenePhase, open: @escaping @MainActor () -> Void)
  {
    defaultsLog.notice("""
      didChangePhase \
      \(String(describing: scenePhase), privacy: .public)
      """)
    self.appPhase = scenePhase
    self.open = open
  }
#endif

}

/// Boot wrapper that runs async processor discovery before
/// constructing the real AppModel. ContentView always mounts as
/// the WindowGroup's content (so `@SceneStorage` and URL
/// restoration work as usual) and branches its body on
/// `boot.model` being non-nil.
@Observable @MainActor
final class AppBoot {
  private(set) var model: AppModel?

  /// Synchronize the `@ObservableDefaults` macro's per-property cache
  /// with the actual on-disk values. Must be called once at app boot,
  /// BEFORE any SwiftUI layout pass.
  ///
  /// Why: the macro maintains a `_<property>` cache that backs its
  /// `userDefaultsDidChange` handler. The cache is initialized to each
  /// property's literal default (not the persisted value) and is only
  /// updated from inside the notification handler. So the FIRST
  /// `UserDefaults.didChangeNotification` received in the process
  /// triggers `withMutation` for every property whose persisted value
  /// differs from its declared default.
  ///
  /// WebKit's `+[NSParagraphArbitrator initialize]` calls
  /// `[NSUserDefaults registerDefaults:]` the first time `WKWebView`
  /// initializes, which posts that notification synchronously from
  /// inside a SwiftUI layout pass (`sizeThatFits` → `makeNSViewController`
  /// → `WKWebView.initWithFrame:configuration:`). The resulting
  /// `withMutation` re-enters `GraphHost.flushTransactions` and trips
  /// the `AG::Graph::value_set` precondition.
  ///
  /// Posting one synchronous notification during boot warms the cache
  /// so the WebKit-triggered notification finds no diffs and skips
  /// the mutation entirely.
  @MainActor static func warmCache() {
    _ = Defaults.shared
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: UserDefaults.standard)
  }

  init() {
    Self.warmCache()
    // Notification permission is presented as a system sheet on
    // first run; awaiting it would block boot until the user
    // responds. Fire it in parallel and let it resolve whenever.
    Task { await UNUserNotificationCenter.requestAuthorization() }
    Task { @MainActor in
#if os(macOS)
      await ActiveServerAgent.shared.restartHelperIfStale {
          Defaults.shared.serverGalleyHash
        } cleaner: {
          Defaults.shared.serverGalleyHash = nil
        }
#endif
      await ProcessorStore.shared.discover()
      self.model = AppModel()
    }
  }
}

#if os(macOS)
extension ActiveServerAgent {
  static let shared = ActiveServerAgent(
    agent: LaunchctlServerAgent(bundle: Bundle.main.serverBundle))
}

extension Bundle {
  public var serverBundle: Bundle? {
    url(forResource: "Galley Server", withExtension: "app")
      .flatMap { url in Bundle(url: url) }
  }
}
#endif
