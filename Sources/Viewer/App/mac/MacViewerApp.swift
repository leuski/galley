#if os(macOS)
import AppKit
import GalleyCoreKit
import SwiftUI
import UniformTypeIdentifiers
import KosmosAppKit

@main
struct MacViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) var appDelegate
  @State private var boot = AppBoot()
  @State private var openModel = ViewerOpenModel()
  @State private var recents = RecentDocumentsModel()
  @State private var kosmos: ViewerKosmosService

  init() {
    URL.createLocalizedApplicationSupportDirectory()
    Self.pinWindowTabbingPreference()
    // If the active server-agent backend persists an absolute path
    // to the helper, the user moving `Galley.app` would leave that
    // record pointing at a stale location. Detect and repair before
    // any UI reflects stale state. No-op when nothing is installed.
    // Fire-and-forget: scenes don't need to wait on it.
    Task { await ActiveServerAgent.shared.validateAndRepair() }
    // Start the Kosmos surface so the peer set populates by the
    // time the menu / pill consult it. Independent of `AppBoot`.
    let kosmos = ViewerKosmosService()
    kosmos.start()
    _kosmos = State(wrappedValue: kosmos)
  }

  /// Force `NSWindow.userTabbingPreference == .always` for this process
  /// via the volatile argument domain (outranks the user's global
  /// "Prefer tabs" setting, but only for us — WindowProbe FINDINGS §8).
  /// That's the substrate the per-open `allowsAutomaticWindowTabbing`
  /// toggle needs so `newTab` opens are born-as-tab without a flash;
  /// `newWindow`/`replaceCurrent` still open standalone because the
  /// toggle is flipped off for them.
  private static func pinWindowTabbingPreference() {
    var domain = UserDefaults.standard
      .volatileDomain(forName: UserDefaults.argumentDomain)
    domain["AppleWindowTabbingMode"] = "always"
    UserDefaults.standard
      .setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
  }

  var body: some Scene {
    // Wire the tab-bar "+" handler (runs the Open panel and opens the
    // picks as tabs onto the source window). Idempotent — body may
    // re-run.
    // swiftlint:disable:next redundant_discardable_let
    let _ = configureRouting()

    // The document scene. SwiftUI materializes one `url == nil` member
    // at cold launch (WindowProbe FINDINGS §3) which `MacContentView`
    // uses as the invisible bootstrap anchor — capturing `openWindow`,
    // hosting `.onOpenURL`, and running the FTUE Open panel. No
    // separate welcome scene is needed.
    WindowGroup(for: URL.self) { $url in
      MacContentView(fileURL: $url)
        .environment(boot)
        .environment(openModel)
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
      WindowCommands(kosmos: kosmos)
      HelpCommands()
    }

    // Singleton Help window. It claims the `galley-help://` scheme via
    // `handlesExternalEvents`, so firing `galley-help://<bundle-path>`
    // at the app opens/raises it and delivers the URL to
    // `HelpWindowView.onOpenURL`. `openModel` + `recents` are injected
    // because the child `DocumentView` reads them.
    // `.restorationBehavior(.disabled)` keeps help out of state
    // restoration — closing the app while help is open doesn't bring it
    // back on relaunch.
    Window("Help", id: "help") {
      HelpWindowView()
        .environment(boot)
        .environment(openModel)
        .environment(recents)
    }
    .handlesExternalEvents(matching: ["galley-help:"])
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
          .environment(kosmos)
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // The Settings scene claims its own `galley-settings://` scheme, so a
    // deep link (e.g. the Server's "Galley Settings…") opens it and the
    // `?tab=` lands via `SettingsView.onOpenURL`.
    .handlesExternalEvents(matching: ["galley-settings:"])
    .defaultSize(width: 580, height: 360)
    .windowResizability(.contentSize)
  }

  private func configureRouting() {
    recents.openModel = openModel
    let recents = recents
    let openModel = openModel
    NewTabAction.handler = { _ in
      Task { @MainActor in
        let picks = await recents.runOpenPanel()
        for url in picks {
          recents.record(url)
          // Born-as-tab into the key window's group (the "+" source is
          // key). No host argument needed — see `ViewerOpenModel`.
          openModel.openAsTab(url)
        }
      }
    }
  }
}
#endif
