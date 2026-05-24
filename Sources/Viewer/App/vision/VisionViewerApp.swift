#if os(visionOS)
import GalleyCoreKit
import SwiftUI

/// visionOS entry point for Galley. Simpler than the macOS counterpart
/// (no AppDelegate, no `WindowDispatcher`), but matches its
/// "invisible anchor scene" pattern: a `Window("home")` always spawns
/// at launch and stays alive across document-window close so the OS
/// doesn't suspend the app while it's still the right routing target
/// for Mac → AVP opens.
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

  init() {
    Defaults.warmCache()
  }

  var body: some Scene {
    // Always-alive anchor scene. visionOS suspends apps with zero
    // visible scenes, which kills the Kosmos client and prevents
    // any further Mac → AVP routing until the user manually
    // re-launches the app. The anchor avoids that by keeping at
    // least one scene present.
    //
    // Visually: `.plain` window style + a `Color.clear` body + a
    // 1×1 frame collapses the volume to as small as visionOS will
    // render. The user can move it out of view; we don't insist
    // on `.persistentSystemOverlays(.hidden)` or anything that
    // forces it to be undismissable.
    //
    // Functionally: this scene owns the kosmos lifecycle —
    // `kosmos.start()`, the `openWindow` capture for inbound
    // `OpenDocument` deliveries, and the `scenePhase` lifecycle
    // publishing. The document `WindowGroup` below only renders
    // document content; if it has no live instances (user closed
    // everything), the anchor still captures opens and spawns fresh
    // doc windows.
    Window("Galley", id: VisionWindowID.home) {
      HomeAnchorView()
        .environment(kosmos)
        .modifier(KosmosClientLifecycleBridge(kosmos: kosmos))
    }
    .windowStyle(.plain)
    .windowResizability(.contentSize)
    .defaultSize(width: 1, height: 1)

    WindowGroup(for: URL.self) { $fileURL in
      VisionContentView(fileURL: $fileURL, boot: boot)
        .environment(recents)
        .environment(kosmos)
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

/// Body of the invisible anchor scene. `Color.clear` + a 1×1 frame
/// makes the volume effectively invisible; `accessibilityHidden`
/// keeps it out of the VoiceOver rotor.
private struct HomeAnchorView: View {
  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .accessibilityHidden(true)
  }
}

/// Capture the document `WindowGroup`'s `openWindow` environment so
/// the Kosmos client can route incoming `OpenURL` / `OpenDocument`
/// messages into a new document window. Also forwards `scenePhase`
/// transitions to the client so the Mac peer learns when AVP is
/// actually serviceable.
///
/// Attached to the always-alive `Window("home")` anchor (not to
/// individual document windows). That way the captured `openWindow`
/// action remains valid even after the user closes every document
/// window — the anchor stays mounted, so the closure is callable
/// indefinitely. With the modifier attached to a doc window, closing
/// the last doc window would unmount the view, leaving
/// `kosmos.onOpenURL` pointing at a stale action that quietly
/// no-ops on the next Mac dispatch.
private struct KosmosClientLifecycleBridge: ViewModifier {
  @Bindable var kosmos: KosmosVisionService
  @Environment(\.openWindow) private var openWindow
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content
      .onAppear {
        kosmos.start()
        kosmos.onOpenURL = { url in openWindow(value: url) }
      }
      .onChange(of: scenePhase, initial: false) { _, newPhase in
        switch newPhase {
        case .active, .inactive:
          kosmos.publishResume()
        case .background:
          kosmos.publishSuspend()
        @unknown default:
          break
        }
      }
  }
}
#endif
