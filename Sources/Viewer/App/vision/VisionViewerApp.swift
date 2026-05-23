#if os(visionOS)
import GalleyCoreKit
import SwiftUI

/// visionOS entry point for Galley. Far simpler than the macOS
/// counterpart — no AppDelegate, no welcome bootstrap scene, no
/// `LaunchArguments` parsing, no `WindowDispatcher` (every URL
/// arrives via `WindowGroup`'s value binding).
///
/// `Defaults.warmCache()` must run before the first SwiftUI layout
/// pass so the first WebKit-driven `UserDefaults.didChangeNotification`
/// can't trip `ObservableDefaults`'s mutation handler mid-flush — see
/// the macOS `Defaults.warmCache()` doc comment for the failure mode.
@main
struct VisionViewerApp: App {
  @State private var boot = AppBoot()
  @State private var recents = RecentDocumentsModel()
  @State private var kosmos = KosmosVisionService()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    Defaults.warmCache()
  }

  var body: some Scene {
    WindowGroup(for: URL.self) { $fileURL in
      VisionContentView(fileURL: $fileURL, boot: boot)
        .environment(recents)
        .environment(kosmos)
        .modifier(KosmosClientLifecycleBridge(kosmos: kosmos))
    }
    .windowResizability(.contentSize)

    // Single settings window. visionOS has no `Settings { ... }`
    // scene type — instead we expose a regular `Window` reached via
    // `openWindow(id:)` from the document toolbar's gear button.
    // `restorationBehavior(.disabled)` keeps the window out of the
    // launch set: closing the app while Settings is open does not
    // bring it back on relaunch.
    Window("Settings", id: VisionWindowID.settings) {
      if let model = boot.model {
        VisionSettingsView(appModel: model)
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .windowResizability(.contentSize)
    .restorationBehavior(.disabled)
    .defaultSize(width: 640, height: 720)
  }
}

/// Capture the document `WindowGroup`'s `openWindow` environment so
/// the Kosmos client can route incoming `OpenURL` messages into a new
/// document window. Also forwards `scenePhase` transitions to the
/// client so the Mac peer learns when AVP suspends/resumes.
///
/// The view itself renders nothing — it lives in the content tree
/// purely to access the `openWindow` environment that's only
/// available inside a SwiftUI body.
private struct KosmosClientLifecycleBridge: ViewModifier {
  @Bindable var kosmos: KosmosVisionService
  @Environment(\.openWindow) private var openWindow

  // Scene-phase observation is intentionally absent. On visionOS,
  // `.background` fires for focus loss / dim-out / window close in
  // ways that don't correspond to true app suspension — and the
  // Kosmos session itself is a strictly better reachability signal:
  // if AVP can receive a message, it's reachable. Publishing
  // `AppWillSuspend` from a noisy phase change just disables the
  // Mac-side menu while an AVP window is plainly visible.

  func body(content: Content) -> some View {
    content
      .onAppear {
        kosmos.start()
        kosmos.onOpenURL = { url in openWindow(value: url) }
      }
  }
}
#endif
