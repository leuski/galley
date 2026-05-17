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

  init() {
    Defaults.warmCache()
  }

  var body: some Scene {
    WindowGroup(for: URL.self) { $fileURL in
      VisionContentView(fileURL: fileURL, boot: boot)
    }

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
    .restorationBehavior(.disabled)
    .defaultSize(width: 640, height: 720)
  }
}
#endif
