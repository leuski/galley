#if os(visionOS)
import GalleyCoreKit
import KosmosAppKit
import SwiftUI

/// visionOS entry point for Galley. Simpler than the macOS counterpart
/// (no AppDelegate, no `WindowDispatcher`).
///
/// Process lifecycle rests on **at least one window always being
/// alive** — visionOS suspends apps with zero scenes, which kills
/// Kosmos and breaks Mac → AVP routing. We achieve that without a
/// dedicated anchor scene by having the document `WindowGroup` host
/// an "empty" instance (nil-URL) whenever no real documents are
/// open: that empty is the welcome surface.
@main
struct VisionViewerApp: App {
  /// The document `WindowGroup`. An instance bound to a nil URL is
  /// the welcome / empty surface; an instance bound to a real URL is
  /// a document window.
  @State private var boot = AppBoot()
  @State private var recents = RecentDocumentsModel()
  @State private var kosmos = VisionKosmosService()
  @Environment(\.openWindow) private var openWindow

  /// Read at the **App** level so SwiftUI hands us the aggregate
  /// phase across all live scenes (`.active` if any scene is active,
  /// `.background` only when every scene is). Reading the same key
  /// inside a Scene's content view would give per-scene phase, which
  /// would fire spuriously on every window close.
  @Environment(\.scenePhase) private var scenePhase

  init() {
    kosmos.start()
  }

  var body: some Scene {
    VisionDocumentScene()
      .environment(boot)
      .environment(recents)
      .environment(kosmos)
      .onChange(of: scenePhase, initial: false) { _, newPhase in
        // App-level (aggregate) phase. Drives Kosmos suspend/resume,
        // and tells the registry to suppress `onNeedEmpty` while the
        // whole app is on its way out — otherwise per-scene
        // `.background` transitions during app backgrounding would
        // each look like a fresh dismissal and try to spawn empties.
        boot.model?.didChangePhase(scenePhase: newPhase) {
          openWindow(id: VisionDocumentScene.id)
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

    VisionSettingsScene()
      .environment(boot)
  }
}

#endif
