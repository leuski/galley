#if os(macOS)
import AppKit
import GalleyCoreKit
import SwiftUI
import UniformTypeIdentifiers
import ALFoundation

@main
struct MacViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) var appDelegate
  @State private var boot = AppBoot()
  @State private var dispatcher: WindowDispatcher
  @State private var recents = RecentDocumentsModel()

  private static func createApplicationSupportDirectory() {
    let localized = GalleyConstants
      .applicationSupportDirectory / ".localized" / "en.strings"
    guard !localized.itemExists else { return }
    try? localized.parent.createDirectory()
    let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
    ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
    ?? ProcessInfo.processInfo.processName
    try? """
    "\(GalleyConstants.suiteName)" = "\(appName)";
    """.write(to: localized, atomically: true, encoding: .utf8)
  }

  init() {
    Self.createApplicationSupportDirectory()
    // Sync the @ObservableDefaults cache with the on-disk values
    // before any SwiftUI scene starts laying out. See
    // `Defaults.warmCache()` for the full rationale — short version:
    // WebKit's first WKWebView.init posts a synchronous
    // UserDefaults.didChangeNotification mid-layout, and an uninitialized
    // cache turns that into a `withMutation` that re-enters the
    // AttributeGraph and crashes.
    Defaults.warmCache()
    // If the active server-agent backend persists an absolute path
    // to the helper, the user moving `Galley.app` would leave that
    // record pointing at a stale location. Detect and repair before
    // any UI reflects stale state. No-op when nothing is installed.
    // Fire-and-forget: scenes don't need to wait on it.
    Task { await ActiveServerAgent.validateAndRepair() }
    let args = LaunchArguments.fromProcess()
    let dispatcher = WindowDispatcher()
    if let seed = args.seedFile {
      // Test-mode injection: pre-populate the launch buffer so the
      // welcome scene drains it on first install. Equivalent to the
      // URL having arrived via `.onOpenURL` immediately at launch.
      dispatcher.enqueueAtLaunch(seed)
    }
    _dispatcher = State(wrappedValue: dispatcher)
  }

  var body: some Scene {
    // Wire the cross-references the recents model needs to dispatch
    // through the same path as Finder dispatches, plus the
    // tab-bar "+" handler that runs the Open panel and merges picks
    // as tabs onto the source window. Both assignments are
    // idempotent — body may re-run.
    // swiftlint:disable:next redundant_discardable_let
    let _ = configureRouting()

    // Always-alive hidden anchor scene. SwiftUI auto-spawns this
    // because it's a `Window` (singular) — guarantees a view exists
    // at launch to capture `openWindow` and host `.onOpenURL` for
    // the URL-typed `WindowGroup` below. See WelcomeView for the
    // full justification.
    Window("Welcome", id: "welcome") {
      WelcomeView()
        .environment(boot)
        .environment(dispatcher)
        .environment(recents)
    }
    // Always present at launch. Without this, SwiftUI may remember
    // a previous "closed" state and skip auto-spawning, leaving us
    // with no view to capture `openWindow`.
    .defaultLaunchBehavior(.presented)
    // Don't persist welcome's "is open" state across launches.
    // We never want it remembered as closed; we always want it
    // ready as the bootstrap anchor.
    .restorationBehavior(.disabled)
    // Strip SwiftUI's auto-generated commands for this scene —
    // notably the Window-menu entry SwiftUI inserts for every
    // `Window` scene. Without this, `Welcome` shows up alongside
    // real document windows in the Window menu and the user can
    // bring it forward (stealing focus from doc windows). The
    // per-NSWindow flags `isExcludedFromWindowsMenu` and
    // `NSApp.removeWindowsItem` operate on the AppKit window
    // list; this scene-level entry is a separate construct that
    // only `.commandsRemoved()` reaches.
    .commandsRemoved()

    WindowGroup(for: URL.self) { $url in
      ContentView(fileURL: $url)
        .environment(boot)
        .environment(dispatcher)
        .environment(recents)
    }
    .defaultSize(width: 700, height: 900)
    .windowToolbarStyle(.unified)
    .commands {
      FileCommands(recents: recents)
      EditCommands()
      ToolbarCommands()
      ViewCommands()
      if let model = boot.model {
        FormatCommands(appModel: model)
      }
      HelpCommands(dispatcher: dispatcher)
    }

    // Singleton Help window. SwiftUI enforces "exactly one" — calling
    // `openWindow(id: "help")` while a Help window is open just brings
    // it forward. The URL to display is held on the dispatcher in
    // `currentHelpURL`; the dispatcher writes it before triggering the
    // open via the installed help handler.
    // `.restorationBehavior(.disabled)` keeps
    // the help window out of state-restoration entirely — closing the
    // app while help is open does not bring it back on relaunch.
    Window("Help", id: "help") {
      HelpWindowView()
        .environment(boot)
        .environment(dispatcher)
        .environment(recents)
    }
    .restorationBehavior(.disabled)
    // Drop SwiftUI's static "Help" entry from the Window menu —
    // AppKit auto-lists the window dynamically once it's visible
    // (and removes the entry when it closes), so the static entry
    // would only show "Help" as an always-present opener even when
    // no help window exists.
    .commandsRemoved()
    .defaultSize(width: 600, height: 900)

    Settings {
      if let model = boot.model {
        SettingsView(appModel: model)
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .defaultSize(width: 580, height: 360)
    .windowResizability(.contentSize)
  }

  private func configureRouting() {
    recents.dispatcher = dispatcher
    let recents = recents
    let dispatcher = dispatcher
    NewTabAction.handler = { source in
      Task { @MainActor in
        let picks = await recents.runOpenPanel()
        for url in picks { recents.record(url) }
        dispatcher.openAsTabs(picks, onto: source)
      }
    }
  }
}
#endif
