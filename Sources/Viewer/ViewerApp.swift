import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) var appDelegate
  @State private var boot = AppBoot()

  var body: some Scene {
    // Always-alive hidden anchor scene. SwiftUI auto-spawns this
    // because it's a `Window` (singular) — guarantees a view exists
    // at launch to capture `openWindow` and host `.onOpenURL` for
    // the URL-typed `WindowGroup` below. See WelcomeView for the
    // full justification.
    Window("Welcome", id: "welcome") {
      WelcomeView()
        .environment(boot)
        .environment(appDelegate)
    }
    // Always present at launch. Without this, SwiftUI may remember
    // a previous "closed" state and skip auto-spawning, leaving us
    // with no view to capture `openWindow`.
    .defaultLaunchBehavior(.presented)
    // Don't persist welcome's "is open" state across launches.
    // We never want it remembered as closed; we always want it
    // ready as the bootstrap anchor.
    .restorationBehavior(.disabled)

    WindowGroup(for: URL.self) { $url in
      WindowRoot(url: $url)
        .environment(boot)
        .environment(appDelegate)
    }
    .defaultSize(width: 700, height: 900)
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      FileCommands(delegate: appDelegate)
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
}

/// Thin wrapper so `@Environment(\.openSettings)` is in scope for the
/// `.onOpenURL` handler that routes `galley://settings` to Viewer
/// Settings. Document-bearing file URLs continue to flow through
/// `ViewerAppDelegate.application(_:open:)`.
private struct WindowRoot: View {
  @Binding var url: URL?
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    ContentView(fileURL: $url)
      .onOpenURL { incoming in
        guard incoming.scheme?.lowercased() == "galley",
              incoming.host?.lowercased() == "settings"
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      }
  }
}
