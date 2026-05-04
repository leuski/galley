import AppKit
import GalleyCoreKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) var appDelegate
  @State private var boot = AppBoot()
  @State private var dispatcher: WindowDispatcher
  @State private var recents = RecentDocumentsModel()

  init() {
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
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      FileCommands(recents: recents)
      ToolbarCommands()
      ViewCommands()
      if let model = boot.model {
        RenderingCommands(appModel: model)
      }
    }

    Settings {
      if let model = boot.model {
        SettingsView(appModel: model)
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(minWidth: 320, minHeight: 200)
      }
    }
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
