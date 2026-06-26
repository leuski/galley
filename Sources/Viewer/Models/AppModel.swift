import Foundation
import GalleyCoreKit
import SwiftUI
import OSLog
import UserNotifications
import WebKit

private let defaultsLog = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

@MainActor @Observable
final class AppModel {
  // MARK: - In-memory state (not persisted by the macro)

  /// The app's single instance. `AppModel` is now the boot point — it
  /// builds synchronously, so there's nothing to defer behind a separate
  /// wrapper (the old `AppBoot`).
  static let shared = AppModel()

  let templates: TemplateChoice
  let processors: ProcessorChoice
  let colorSchemes: ColorSchemeChoice

  var isOpenFilePresented = false

  /// App-wide collaborators that used to live on `AppBoot`.
  let kosmos = ViewerKosmosService()
  let recents = RecentDocumentsModel()

  @ObservationIgnored private var persistenceTokens: [Cancellable] = []

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

#if ENABLE_TUNNEL
  // Lazy so it can read `self.kosmos` (a stored property is available
  // only after phase-1 init); resolved on first use in `urlSchemeHandler`.
  @ObservationIgnored private lazy var tunnelHandler =
  KosmosTunnelSchemeHandler(tunnel: kosmos.tunnel)
    .schemeHandler
#endif

  /// The app's single boot point (replaces the old `AppBoot`). Builds
  /// synchronously: choices decode from the shared defaults suite now,
  /// and processor discovery runs *after* in a background task — the
  /// `ProcessorChoice` reflects the expanded catalog reactively, so
  /// nothing waits. Processor / template selections stay in sync with
  /// the suite both ways (Server writes propagate via
  /// `limitToInstance: false`).
  init() {
    Self.warmCache()
    Self.logInit(
      bundle: Bundle.main.bundleIdentifier,
      renderer: Defaults.shared.renderer,
      template: Defaults.shared.template)

#if os(macOS)
    URL.createLocalizedApplicationSupportDirectory()
    UserDefaults.forceTabs()
    persistenceTokens.append(onObservedChange {
      _ = Defaults.shared.openBehavior
    } onChange: {
      NSWindow.allowsAutomaticWindowTabbing = Defaults
        .shared.openBehavior == .newTab
    })
    self.editors = EditorChoice()
    /// The AppKit tab-bar "+" runs the Open panel and fires each pick as an
    /// activity URL. The "+" only exists when windows are already tabbed
    /// (new-tab behavior → `syncWindowTabbing` left the toggle on), so the
    /// picks are born-as-tab.
    NewTabAction.handler = { _ in
      Task { @MainActor in
        AppModel.shared.isOpenFilePresented = true
      }
    }
#endif

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

    persistenceTokens += bindPersistent(
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

    Self.logDefaultsDidChange()

    // Boot side-effects (formerly `AppBoot.init`). Fired in parallel so
    // they never block the first scene; the processor catalog expands
    // behind the already-built `ProcessorChoice`.
    Task { await UNUserNotificationCenter.requestAuthorization() }
    Task { @MainActor in
#if os(macOS)
      await ActiveServerAgent.shared.restartHelperIfStale {
        Defaults.shared.serverGalleyHash
      } cleaner: {
        Defaults.shared.serverGalleyHash = nil
      }
      // If the active server-agent backend persists an absolute path
      // to the helper, the user moving `Galley.app` would leave that
      // record pointing at a stale location. Detect and repair before
      // any UI reflects stale state. No-op when nothing is installed.
      // Fire-and-forget: scenes don't need to wait on it.
      await ActiveServerAgent.shared.validateAndRepair()
#endif
      await ProcessorStore.shared.discover()
    }
    kosmos.start()
  }

  static func logDefaultsDidChange() {
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

  public func resolvedTemplate(
    templates: SceneTemplateChoice?) -> Template
  {
    if let templates, Defaults.shared.enablePerDocumentOverrides {
      return templates.selected.value
    }
    return self.templates.selected.value
  }

  public func urlSchemeHandler(
    templates: SceneTemplateChoice) -> [URLScheme: AnySchemeHandler]
  {
    let localHandler = PreviewSchemeHandler { [weak templates] in
      self.resolvedTemplate(templates: templates)
    }.schemeHandler
#if ENABLE_TUNNEL
    return [
      PreviewSchemeHandler.scheme: localHandler,
      KosmosTunnelSchemeHandler.scheme: tunnelHandler
    ]
#else
    return [
      PreviewSchemeHandler.scheme: localHandler
    ]
#endif
  }

  private static func notify(
    _ kind: UNUserNotificationCenter.Kind, _ name: String)
  {
    UNUserNotificationCenter.post(kind: kind, displaced: name)
  }

  /// Synchronize the `@ObservableDefaults` macro's per-property cache
  /// with the on-disk values, BEFORE any SwiftUI layout pass. Called
  /// first thing in `init`.
  ///
  /// Why: the macro seeds each `_<property>` cache to the *declared*
  /// default, updating only inside its `userDefaultsDidChange` handler.
  /// WebKit posts a synchronous `UserDefaults.didChangeNotification`
  /// from inside the first `WKWebView.init` (during a SwiftUI layout
  /// pass); the resulting `withMutation` re-enters AttributeGraph and
  /// trips `AG::Graph::value_set`. Posting one notification now warms the
  /// cache so the WebKit-triggered one finds no diffs and skips the
  /// mutation.
  @MainActor static func warmCache() {
    _ = Defaults.shared
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: UserDefaults.standard)
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

#if os(macOS)
extension ActiveServerAgent {
  static let shared = ActiveServerAgent(
    agent: LaunchctlServerAgent(bundle: Bundle.main.serverBundle))
}

extension Bundle {
  public var serverBundle: Bundle? {
    urls(forResourcesWithExtension: "app", subdirectory: nil)?
      .compactMap { url in Bundle(url: url) }
      .filter { bundle in
        bundle.bundleIdentifier == "net.leuski.galley.server" }
      .first
  }
}
#endif
