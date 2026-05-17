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
  }
}
#endif
