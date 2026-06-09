import GalleyCoreKit
import SwiftUI
import KosmosAppKit

@main
struct ViewerApp: App {
  @State private var boot = AppBoot()
  @State private var recents = RecentDocumentsModel()
#if os(macOS)
  @State private var kosmos = ViewerKosmosService()
#else
  @State private var kosmos = VisionKosmosService()
  @Environment(\.openWindow) private var openWindow
  /// Read at the **App** level so SwiftUI hands us the aggregate
  /// phase across all live scenes (`.active` if any scene is active,
  /// `.background` only when every scene is). Reading the same key
  /// inside a Scene's content view would give per-scene phase, which
  /// would fire spuriously on every window close.
  @Environment(\.scenePhase) private var scenePhase
#endif

  init() {
#if os(macOS)
    URL.createLocalizedApplicationSupportDirectory()
    UserDefaults.forceTabs()
    // If the active server-agent backend persists an absolute path
    // to the helper, the user moving `Galley.app` would leave that
    // record pointing at a stale location. Detect and repair before
    // any UI reflects stale state. No-op when nothing is installed.
    // Fire-and-forget: scenes don't need to wait on it.
    Task { await ActiveServerAgent.shared.validateAndRepair() }
    // Start the Kosmos surface so the peer set populates by the
    // time the menu / pill consult it. Independent of `AppBoot`.
#else

#endif
    kosmos.start()
  }

  var body: some Scene {
    DocumentScene()
      .environment(boot)
      .environment(recents)
      .environment(kosmos)
#if os(visionOS)
      .onChange(of: scenePhase, initial: false) { _, newPhase in
        // App-level (aggregate) phase. Drives Kosmos suspend/resume,
        // and tells the registry to suppress `onNeedEmpty` while the
        // whole app is on its way out — otherwise per-scene
        // `.background` transitions during app backgrounding would
        // each look like a fresh dismissal and try to spawn empties.
        boot.model?.didChangePhase(scenePhase: newPhase) {
          openWindow(id: DocumentScene.id)
        }
        switch newPhase {
        case .active, .inactive:
          kosmos.publishResume()
        case .background:
          kosmos.publishSuspend()
        @unknown default:
          break
        }
      }
#endif

#if os(macOS)
    MacHelpScene()
      .environment(boot)
      .environment(recents)
#endif

    SettingsScene()
      .environment(boot)
      .environment(kosmos)
  }
}
