#if !os(macOS)

import GalleyCoreKit
import KosmosAppKit
import SwiftUI
import ALFoundation

/// Document-window content view for visionOS. Boot-gated wrapper:
/// shows a progress spinner while async catalog discovery is in
/// flight, a welcome landing surface when the WindowGroup binding
/// has no URL yet, and `VisionDocumentScreen` once both `AppModel` and a
/// `fileURL` are available.
struct VisionContentView: View {
  @Binding var target: DocumentTarget?
  @Environment(AppBoot.self) private var boot

  @Environment(\.dismissWindow) private var dismissWindow
  /// Per-scene phase. `.background` fires for *this* window when
  /// the user dismisses it, including for the last window of the
  /// app — where `.onDisappear` doesn't fire (visionOS quirk).
  @Environment(\.scenePhase) private var scenePhase
  /// Stable per-window identity. `@State` outlives child view
  /// rebinds (welcome ↔ document), so registration tracks the
  /// window, not the current screen.
  @State private var windowID = UUID()

  var body: some View {
    Group {
      if let model = boot.model {
        if let target = Binding($target) {
          VisionDocumentScreen(
            target: target,
            appModel: model)
          .navigationSplitViewStyle(.balanced)
        } else {
          VisionWelcomeScreen(target: $target)
        }
      } else {
        ProgressView()
          .controlSize(.large)
      }
    }
    .onChange(of: scenePhase, initial: true) { _, newPhase in
      if newPhase == .background {
        boot.model?.didDismissWindow(url: target?.documentURL)
        // Force-dismiss the last window, otherwise it leaks memory and
        // jams the Kosmos tunnel (if any).
        dismissWindow()
      }
    }
  }
}
#endif
