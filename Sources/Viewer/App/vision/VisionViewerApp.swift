#if os(visionOS)
import GalleyCoreKit
import SwiftUI

/// visionOS entry point for Galley. Simpler than the macOS counterpart
/// (no AppDelegate, no `WindowDispatcher`).
///
/// Process lifecycle rests on **at least one window always being
/// alive** — visionOS suspends apps with zero scenes, which kills
/// Kosmos and breaks Mac → AVP routing. We achieve that without a
/// dedicated anchor scene by having the document `WindowGroup` host
/// an "empty" instance (nil-URL) whenever no real documents are
/// open: that empty is the welcome surface. The
/// `VisionWindowRegistry` re-spawns one whenever the last document
/// window closes. The user can explicitly close the empty to opt
/// out — when that happens the app suspends, which matches intent.
@main
struct VisionViewerApp: App {
  /// The document `WindowGroup`. An instance bound to a nil URL is
  /// the welcome / empty surface; an instance bound to a real URL is
  /// a document window.
  static let main = "main"
  static let settings = "settings"

  @State private var boot = AppBoot()
  @State private var recents = RecentDocumentsModel()
  @State private var kosmos = VisionKosmosService()
  @State private var registry = VisionWindowRegistry()

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
    WindowGroup(id: Self.main, for: URL.self) { $fileURL in
      VisionContentView(fileURL: $fileURL, boot: boot)
        .environment(recents)
        .environment(kosmos)
        .environment(registry)
        .modifier(KosmosOpenURLBinder(kosmos: kosmos, registry: registry))
    }
    .windowResizability(.contentSize)
    .onChange(of: scenePhase, initial: false) { _, newPhase in
      // App-level (aggregate) phase. Drives Kosmos suspend/resume,
      // and tells the registry to suppress `onNeedEmpty` while the
      // whole app is on its way out — otherwise per-scene
      // `.background` transitions during app backgrounding would
      // each look like a fresh dismissal and try to spawn empties.
      switch newPhase {
      case .active, .inactive:
        kosmos.publishResume()
      case .background:
        kosmos.publishSuspend()
      @unknown default:
        break
      }
    }

    // Single settings window. visionOS has no `Settings { ... }`
    // scene type — instead we expose a regular `Window` reached via
    // `openWindow(id:)` from the document toolbar's gear button.
    // `restorationBehavior(.disabled)` keeps the window out of the
    // launch set: closing the app while Settings is open does not
    // bring it back on relaunch.
    Window("Settings", id: Self.settings) {
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

/// Captures `openWindow` from inside the document `WindowGroup` and
/// wires it into:
///
/// - `kosmos.onOpenURL` — Mac → AVP `OpenDocument` arrives → open the
///   doc window, then ask welcome surfaces to step aside. Order
///   matters: opening the doc first ensures `docCount > 0` before
///   the empty disappears, otherwise the empty's `noteDisappeared`
///   would briefly hit zero and re-spawn yet another empty via
///   `onNeedEmpty`.
///
/// - `registry.onNeedEmpty` — last document window closed and no
///   empty is open → spawn a fresh empty welcome surface so the app
///   stays alive.
///
/// Both closures use the same `openWindow` instance. WindowGroup
/// content remounts on every window, but the closure each captures
/// is functionally equivalent, so re-binding on every appear is
/// idempotent.
private struct KosmosOpenURLBinder: ViewModifier {
  let kosmos: VisionKosmosService
  let registry: VisionWindowRegistry
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      kosmos.onOpenURL = { url in
        registry.openURL(url)
      }
      registry.openWindow = openWindow
    }
  }
}
#endif
