import AppKit
import Foundation
import GalleyCoreKit
import SwiftUI
import os

private let defaultsLog = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

/// App-wide rendering preferences for the Viewer. Renderer selection
/// (catalog discovery + persisted ID), template store, server config,
/// and window-open behavior all live here, separately from any single
/// window's `DocumentModel`. Windows read the active renderer + template
/// at render time, so the user can switch globally and have every open
/// document re-render.
///
/// Backed by `@ObservableDefaults` on `UserDefaults.standard` — for
/// the Viewer that's `~/Library/Preferences/net.leuski.galley.plist`,
/// the same plist the Server reaches via
/// `UserDefaults(suiteName: "net.leuski.galley")`. (The Viewer cannot
/// itself open a suite with that name: `UserDefaults(suiteName:)`
/// returns nil when the suite equals the calling app's own bundle
/// id.) `limitToInstance: false` widens the local observer to react
/// to any UserDefaults change in this process; cross-process change
/// signaling is handled separately by `DefaultsBroadcast` (Darwin
/// notification) because `UserDefaults.didChangeNotification` is
/// process-local.
@ObservableDefaults(limitToInstance: false)
final class Defaults: GalleyNetworkDefaults, GalleyRenderDefaults {
  @DefaultsKey var port: UInt16 = GalleyConstants.defaultPort
  @DefaultsKey var renderer: String?
  @DefaultsKey var template: String?
  @DefaultsKey var enablePerDocumentOverrides: Bool = false
  @DefaultsKey var openBehavior: OpenBehavior = .newWindow
  @DefaultsKey var editor: EditorChoice.Element = .preset(.bbedit)
  @DefaultsKey var perFileStateStore: [String: PerFileState] = [:]
  /// Per-template page background colors, captured by
  /// `BackgroundColorBridge` after each render. Used by
  /// `Template.backgroundState` so a freshly-opened tab can paint
  /// the chrome with the right tint immediately, and by FindBar /
  /// DocumentView for the same reason.
  @DefaultsKey var templateBackgroundColors: [String: TemplateBackgroundState]
  = [:]
  /// Most recent opaque page bg observed by *any* template. Used as
  /// a global fallback when the currently-resolved template hasn't
  /// reported yet — opening a new tab using a never-seen template
  /// hydrates with this last-seen color instead of flashing to the
  /// system default. Empty string means no color has been observed
  /// in this session or any past session yet.
  @DefaultsKey var lastTemplateBackgroundColor: TemplateBackgroundState
  = .unresolved

  @MainActor static let shared = Defaults()
}

@MainActor @Observable
final class AppModel {
  // MARK: - In-memory state (not persisted by the macro)

  let templates: TemplateChoice
  let processors: ProcessorChoice
  @ObservationIgnored let editors: EditorChoice
  @ObservationIgnored private var persistenceTokens: [Cancelable] = []

  /// Tab the Settings scene should display. The bootstrap modifier
  /// writes here when a `galley://settings?tab=<id>` URL arrives, just
  /// before invoking `openSettings()`. `SettingsView` binds its
  /// `TabView` selection to this property so external deep links can
  /// land on the right pane.
  var selectedSettingsTab: SettingsTab = .general

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
    self.editors = EditorChoice()

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

    // Darwin-notification bridge: `UserDefaults.didChangeNotification`
    // is process-local, so the Server (a near-idle menu-bar app) never
    // wakes up to re-read the shared suite when the Viewer writes.
    // `startListening` translates inbound Darwin notifications into a
    // local didChangeNotification post that the ObservableDefaults
    // macro observer is already subscribed to. `post()` after each
    // outbound write fires the cross-process signal.
    DefaultsBroadcast.startListening()

    persistenceTokens = bindPersistent(
      templates,
      label: "Viewer.template",
      read: { Defaults.shared.template },
      write: {
        Defaults.shared.template = $0
        DefaultsBroadcast.post()
      })
    + bindPersistent(
      processors,
      label: "Viewer.processor",
      read: { Defaults.shared.renderer },
      write: {
        Defaults.shared.renderer = $0
        DefaultsBroadcast.post()
      })

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
    _ kind: DisplacementNotifier.Kind, _ name: String)
  {
    DisplacementNotifier.post(kind: kind, displaced: name)
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
}

/// Boot wrapper that runs async processor discovery before
/// constructing the real AppModel. ContentView always mounts as
/// the WindowGroup's content (so `@SceneStorage` and URL
/// restoration work as usual) and branches its body on
/// `boot.model` being non-nil.
@Observable @MainActor
final class AppBoot {
  private(set) var model: AppModel?

  init() {
    // Notification permission is presented as a system sheet on
    // first run; awaiting it would block boot until the user
    // responds. Fire it in parallel and let it resolve whenever.
    Task { await DisplacementNotifier.requestAuthorization() }
    Task { @MainActor in
      await Self.restartServerIfStale()
      await ProcessorStore.shared.discover()
      self.model = AppModel()
    }
  }

  /// Compare our Galley.app hash with whatever the running Server
  /// published. If they disagree, terminate and relaunch the Server.
  /// We do this *before* constructing `AppModel` so the bindPersistent
  /// observers aren't installed during the kill window — the stale
  /// Server can't get one last clobber in by reconciling defaults
  /// against its (smaller) catalog.
  ///
  /// The "stale Server" failure mode is real: the Server is the
  /// menu-bar process that owns its own `TemplateChoice`, hooked to
  /// the same shared plist via `bindPersistent`. When its catalog
  /// doesn't recognize a value the Viewer just wrote (e.g. a new
  /// bundled template added in the Viewer build but not in the
  /// running Server), reconcile() snaps the Server's selection back
  /// to default and the inbound observer mirrors that back to
  /// storage, undoing the Viewer's pick on every change.
  private static func restartServerIfStale() async {
    let bundleID = "net.leuski.galley.server"
    let runningServers = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleID)
    guard let runningServer = runningServers.first else { return }

    do {
      let myHash = try await GalleyAppHash.compute(at: Bundle.main.bundleURL)
      let theirHash = SharedSuiteDefaults.suite.string(
        forKey: SharedSuiteDefaults.serverGalleyHashKey)
      // Missing-hash case is the first launch after this validation
      // shipped, where the running Server pre-dates the publish
      // logic. Treat it the same as a mismatch: restart so the new
      // Server can publish and we converge from then on.
      if let theirHash, theirHash == myHash { return }

      defaultsLog.notice("""
        Galley.app hash mismatch with running Server (\
        ours=\(myHash.prefix(8), privacy: .public)… \
        theirs=\(theirHash?.prefix(8) ?? "nil", privacy: .public)…) — \
        restarting Server
        """)

      // Drop the published hash before terminating so a re-read
      // during the kill window doesn't re-trigger this branch.
      SharedSuiteDefaults.suite.removeObject(
        forKey: SharedSuiteDefaults.serverGalleyHashKey)

      runningServer.terminate()
      // Poll up to 5s for the process to exit. terminate() is
      // asynchronous; we don't want to relaunch until the old PID
      // is gone or NSWorkspace will treat it as a no-op activation.
      for _ in 0..<50 {
        if NSRunningApplication
          .runningApplications(withBundleIdentifier: bundleID).isEmpty {
          break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }

      let serverURL = Bundle.main.bundleURL
        .appending(path: "Contents/Resources/Galley Server.app")
      guard FileManager.default.fileExists(atPath: serverURL.path) else {
        defaultsLog.error("""
          Galley Server.app missing inside this Galley.app — \
          cannot relaunch Server
          """)
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      _ = try await NSWorkspace.shared.openApplication(
        at: serverURL, configuration: configuration)
    } catch {
      defaultsLog.error("""
        Server staleness check failed: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }
}
