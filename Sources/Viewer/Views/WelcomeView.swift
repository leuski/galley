import AppKit
import GalleyCoreKit
import SwiftUI

/// Bootstrap scene for the Viewer — when it mounts.
///
/// SwiftUI's `WindowGroup(for: URL.self)` does not auto-spawn a
/// window when there's no URL, and `applicationShouldOpenUntitledFile`
/// is not bridged for value-driven window groups. That breaks the
/// truly empty cold-launch path: no view alive means no
/// `@Environment(\.openWindow)` to capture, queued URLs never
/// drain, the FTUE Open panel never appears.
///
/// `Window("welcome")` is the singular anchor scene that solves
/// that case. The window is configured to be invisible and
/// non-interactive (alpha=0, ignores mouse events, excluded from
/// the Window menu, no chrome).
///
/// On macOS 26, SwiftUI does NOT reliably mount this scene when
/// state restoration produces doc windows, so the launch-time
/// dispatch wiring (capture `openWindow`, host `.onOpenURL`)
/// lives in `BootstrapDispatchModifier` and is also attached to
/// every doc window. Welcome retains exclusive ownership of the
/// FTUE Open panel — when it does mount (truly empty launch),
/// it's the only scene that can run that flow.
struct WelcomeView: View {
  @Environment(AppBoot.self) private var boot
  @Environment(WindowDispatcher.self) private var dispatcher
  @Environment(RecentDocumentsModel.self) private var recents
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .background(WindowAccessor(onAttach: configureHidden))
      .task(id: boot.model != nil) {
        guard boot.model != nil else { return }
        await runFTUEIfNeeded()
      }
      .bootstrapDispatch()
  }

  // MARK: - Hidden-window configuration

  /// Applies every NSWindow knob needed to make the welcome window
  /// invisible AND non-interactive. `alphaValue = 0` alone leaves a
  /// click-eating phantom window in the visible bounds, so we layer
  /// other flags on top.
  ///
  /// Things to NOT do here:
  /// - `styleMask = .borderless` forces AppKit to recreate the
  ///   window, which detaches the SwiftUI hosting view and cancels
  ///   `.task` mid-flight.
  /// - `setFrame(...)` to an extreme offscreen position (e.g.
  ///   {-10000, -10000, 1, 1}) crashes inside AppKit's constraint
  ///   solver during `_postWindowNeedsUpdateConstraints`.
  ///
  /// SwiftUI re-asserts a Window-menu entry for `Window` scenes
  /// even after `isExcludedFromWindowsMenu = true`, so we also call
  /// `NSApp.removeWindowsItem(window)` to drop our entry from the
  /// menu after SwiftUI has had its say.
  ///
  /// Welcome still *can* become key (the user can route focus to it
  /// via cmd-` cycling, AppleScript, etc.), and that would steal
  /// focus from a real document window. We attach a
  /// `didBecomeKeyNotification` observer that redirects key status
  /// to the first eligible visible document window the moment
  /// welcome becomes key.
  private func configureHidden(_ window: NSWindow?) {
    guard let window else { return }
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.isExcludedFromWindowsMenu = true
    NSApp.removeWindowsItem(window)
    window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
    window.hasShadow = false
    window.isReleasedWhenClosed = false

    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: window,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        // Find a visible, hittable document window and route focus
        // there. If welcome is somehow the only visible window
        // (e.g., last doc just closed and welcome got promoted),
        // there's nothing to redirect to — just resign key. The
        // brief flash where welcome is key is acceptable; the
        // important guarantee is that focus doesn't *stay* on it.
        let alternate = NSApp.windows.first { other in
          other !== window
            && other.isVisible
            && other.alphaValue > 0.01
            && other.canBecomeKey
        }
        if let alternate {
          alternate.makeKeyAndOrderFront(nil)
        } else {
          window.resignKey()
        }
      }
    }
  }

  // MARK: - FTUE

  /// Runs once after the welcome window mounts. The dispatch wiring
  /// (install + URL receipt) lives in `BootstrapDispatchModifier`;
  /// this method only owns the FTUE Open panel for the cold-launch
  /// path where nothing else opens a window.
  ///
  /// State restoration brings back `WindowGroup<URL>` windows during
  /// launch; we let them settle for 250ms before deciding whether
  /// the user genuinely arrived with no documents. If there's any
  /// doc window already, FTUE bows out.
  private func runFTUEIfNeeded() async {
    try? await Task.sleep(for: .milliseconds(250))
    if Task.isCancelled { return }
    if dispatcher.hasAnyDocumentWindow() { return }

    let picks = await recents.runOpenPanel()
    if Task.isCancelled { return }
    let action = openWindow
    for url in picks {
      recents.record(url)
      action(value: url)
    }
  }
}
