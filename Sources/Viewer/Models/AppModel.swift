import Foundation
import GalleyCoreKit
import KosmosAppKit
import SwiftUI
import OSLog
import ALFoundation

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
#if os(macOS)
      await Self.restartServerIfStale()
#endif
      await ProcessorStore.shared.discover()
      self.model = AppModel()
    }
  }

#if os(macOS)
  /// Compare our Galley.app hash with whatever each running Server
  /// published. Terminate every Server whose `bundleURL` is not the
  /// `Galley Server.app` inside *this* Galley.app, plus any whose
  /// published hash doesn't match ours. If we ended up with no Server
  /// (because we killed all of them, or there were none to begin with
  /// but the hash diverged), relaunch the canonical one.
  ///
  /// Why walk *all* running Servers, not just `.first`: across dev
  /// rebuilds and across the launchctl-managed path vs. Xcode's
  /// `NSWorkspace.open`, multiple Server pids accumulate. The earlier
  /// `runningServers.first` reap left the others in place, and a
  /// stale one could still publish hashes / hold the port file open.
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
    guard let serverBundle = Bundle.main.serverBundle
    else {
      defaultsLog.error("""
        Galley Server.app missing inside this Galley.app — \
        cannot relaunch Server
        """)
      return
    }

    guard let bundleID = serverBundle.bundleIdentifier
    else {
      defaultsLog.error("""
        Galley Server.app missing bundle identifier
        """)
      return
    }

    let canonicalServerURL = serverBundle.bundleURL.safe

    let runningServers = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleID)

    let myHash: String
    do {
      myHash = try await Bundle.main.bundleURL.computeHash()
    } catch {
      defaultsLog.error("""
        Server staleness check failed to hash Galley.app: \
        \(error.localizedDescription, privacy: .public)
        """)
      return
    }
    let theirHash = Defaults.shared.serverGalleyHash

    let hashMatches: Bool = {
      guard let theirHash else { return false }
      return theirHash == myHash
    }()

    // Partition: a Server is "stale" if its bundleURL points outside
    // the canonical bundled location. If every running Server points
    // at the canonical path AND the published hash matches, we have
    // nothing to do.
    let staleServers = runningServers.filter {
      $0.bundleURL?.safe != canonicalServerURL
    }
    if staleServers.isEmpty && hashMatches { return }

    defaultsLog.notice("""
      Reaping Server processes (stale=\(staleServers.count, privacy: .public) \
      total=\(runningServers.count, privacy: .public) \
      hashMatch=\(hashMatches, privacy: .public)) ours=\
      \(myHash.prefix(8), privacy: .public)… theirs=\
      \(theirHash?.prefix(8) ?? "nil", privacy: .public)…
      """)

    // Drop the published hash before terminating so a re-read during
    // the kill window doesn't re-trigger this branch.
    Defaults.shared.serverGalleyHash = nil

    // Reap every stale Server, plus all of them if the hash diverged
    // (we don't know which one is publishing the wrong hash).
    let toReap = hashMatches ? staleServers : runningServers
    for running in toReap { running.terminate() }

    // Poll up to 5s for the reaped pids to exit. terminate() is
    // asynchronous; relaunching before they're gone makes
    // NSWorkspace.openApplication a no-op activation.
    await Self.waitForExit(
      pids: Set(toReap.map { app in app.processIdentifier }),
      bundleID: bundleID)

    // If at least one canonical-path Server survived the reap and the
    // hash was the only mismatch, the survivor will republish on its
    // next AppModel.init — nothing more to do.
    let survivors = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleID)
    if !survivors.isEmpty { return }

    // Prefer `launchctl kickstart -k` when the agent is installed:
    // launchd serializes through one source of truth, so calling it
    // twice in quick succession still produces exactly one running
    // process. `NSWorkspace.openApplication` racing against itself
    // (typical when two Galley.apps run on the same login) is the
    // origin of the duplicate-Server bug we're closing here. If the
    // agent isn't bootstrapped we fall through to openApplication.
    if await ActiveServerAgent.shared.kickstart() { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    do {
      _ = try await NSWorkspace.shared.openApplication(
        at: canonicalServerURL, configuration: configuration)
    } catch {
      defaultsLog.error("""
        Server relaunch failed: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  private static func waitForExit(
    pids: Set<Int32>, bundleID: String
  ) async {
    for _ in 0..<50 {
      let stillRunning = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .map { app in app.processIdentifier }
      if stillRunning.allSatisfy({ !pids.contains($0) }) { break }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }
#endif
}
