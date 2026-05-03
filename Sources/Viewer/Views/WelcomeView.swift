import AppKit
import GalleyCoreKit
import SwiftUI

/// Always-alive bootstrap scene for the Viewer.
///
/// SwiftUI's `WindowGroup(for: URL.self)` does not auto-spawn a
/// window when there's no URL, and `applicationShouldOpenUntitledFile`
/// is not bridged for value-driven window groups. That breaks the
/// cold-launch path: with no view alive, no `@Environment(\.openWindow)`
/// is captured, the `ViewerAppDelegate.launchBuffer` never drains,
/// and Finder-dispatched URLs never become document windows.
///
/// `Window("welcome")` (singular scene) auto-spawns at launch and is
/// restored by SwiftUI across sessions. `WelcomeView` is its content;
/// it captures `openWindow`, hands it to the delegate via `install()`,
/// and runs the FTUE Open panel if the launch had nothing queued.
///
/// The window itself is configured to be invisible and
/// non-interactive (alpha=0, off-screen, ignores mouse events,
/// excluded from the Window menu, no chrome). Users never see it.
/// It exists only as the always-on adapter between AppKit's
/// process-level events and SwiftUI's view-bound APIs.
struct WelcomeView: View {
  @Environment(AppBoot.self) private var boot
  @Environment(WindowDispatcher.self) private var dispatcher
  @Environment(RecentDocumentsModel.self) private var recents
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .background(WindowAccessor(onAttach: configureHidden))
      .task(id: boot.model != nil) {
        // Re-fires when boot.model flips from nil to non-nil. Bail
        // until ready; then run once. install() is idempotent on
        // the dispatcher side (subsequent calls overwrite the
        // openHandler with the latest captured action), so even if
        // SwiftUI invalidates and re-fires this task with a fresh
        // closure, we recapture openWindow rather than getting
        // stuck with a stale handler.
        guard boot.model != nil else { return }
        await runLaunchTask()
      }
      .onOpenURL { url in
        // Catches Finder dispatches, NSWorkspace.open(_:),
        // galley:// URL scheme handlers, and dock-icon drops.
        // Welcome is always alive, so this always has a chance to
        // fire — replaces the AppDelegate's
        // application(_:open:) hook.
        //
        // `galley://settings` works even when no document window is
        // open: the dispatcher hands the openSettings outcome back
        // to us via `onSettingsRequested`, and we activate the app
        // (otherwise the Settings window would open behind whatever
        // app the user clicked from, e.g. the Server menu bar).
        dispatcher.handleOpenURLs([url]) {
          NSApp.activate(ignoringOtherApps: true)
          openSettings()
        }
        // Keep the recents list in sync. recents.openRecent goes
        // through dispatcher.handleOpenURLs again, so we record
        // directly to avoid double-dispatch.
        switch URLNormalizer.normalize(url) {
        case .openSettings: break
        case .document(let fileURL, _): recents.record(fileURL)
        case .unparseable(let original): recents.record(original)
        }
      }
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

  // MARK: - Bootstrap

  /// Runs once after the welcome window mounts. Installs the
  /// `openWindow` action with the AppDelegate so any queued URLs
  /// drain immediately and any future `application(_:open:)`
  /// dispatches can spawn document windows.
  ///
  /// If nothing was queued and no document windows are alive (cold
  /// launch with no Finder URL, no state restoration), runs the
  /// FTUE Open panel so the user has a way to open something.
  private func runLaunchTask() async {
    guard boot.model != nil else { return }

    // Capture openWindow for the dispatcher. install() returns
    // true when the launch buffer had pending URLs (Finder
    // dispatched before any view existed); each gets replayed
    // through openWindow(value:) here, spawning real document
    // windows.
    let action = openWindow
    let flushed = dispatcher.install { url in
      action(value: url)
    }

    if flushed { return }

    // Settle: state restoration brings back WindowGroup<URL>
    // windows during launch; give them a beat to register so the
    // FTUE picker doesn't run on top of restored docs. Boot is
    // already complete by this point (we got here from
    // `task(id: boot.model != nil)` flipping to true), so a
    // fixed sleep is enough.
    try? await Task.sleep(for: .milliseconds(250))
    if Task.isCancelled { return }

    if dispatcher.hasAnyDocumentWindow() { return }

    // Truly empty launch — present the FTUE Open panel.
    let picks = await recents.runOpenPanel()
    if Task.isCancelled { return }
    for url in picks {
      recents.record(url)
      action(value: url)
    }
  }
}
