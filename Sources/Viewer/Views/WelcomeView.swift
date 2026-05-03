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
  @Environment(ViewerAppDelegate.self) private var appDelegate
  @Environment(WindowDispatcher.self) private var dispatcher
  @Environment(RecentDocumentsModel.self) private var recents
  @Environment(\.openWindow) private var openWindow

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
        dispatcher.handleOpenURLs([url])
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
  /// click-eating phantom window in the visible bounds, so we layer:
  ///
  /// - `ignoresMouseEvents = true`    → clicks pass through
  /// - off-screen frame                → not in any visible region
  /// - `isExcludedFromWindowsMenu`     → not listed in Window menu
  /// - `collectionBehavior` flags      → not in Mission Control or
  ///                                     window cycle
  /// - `styleMask = .borderless`       → no title bar / traffic lights
  /// - `hasShadow = false`             → no shadow leaking onto screen
  /// - `isReleasedWhenClosed = false`  → survives any spurious close
  private func configureHidden(_ window: NSWindow?) {
    guard let window else { return }
    // Things to NOT do here:
    // - `styleMask = .borderless` forces AppKit to recreate the
    //   window, which detaches the SwiftUI hosting view and cancels
    //   `.task` mid-flight.
    // - `setFrame(...)` to an extreme offscreen position (e.g.
    //   {-10000, -10000, 1, 1}) crashes inside AppKit's constraint
    //   solver during `_postWindowNeedsUpdateConstraints`.
    //
    // alpha=0 + ignoresMouseEvents is enough to make it invisible
    // and non-interactive. The other flags keep it out of menus,
    // Mission Control, and the cmd-` cycle so the user never finds
    // it indirectly.
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.isExcludedFromWindowsMenu = true
    window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
    window.hasShadow = false
    window.isReleasedWhenClosed = false
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
    guard let appModel = boot.model else { return }

    // Keep the delegate's appModel reference fresh — `dispatch`
    // consults `openBehavior` through it.
    appDelegate.appModel = appModel

    // Capture openWindow for the dispatcher. install() returns true
    // when the launch buffer had pending URLs (Finder dispatched
    // before any view existed); each gets replayed through
    // openWindow(value:) here, spawning real document windows.
    let action = openWindow
    let flushed = dispatcher.install { url in
      action(value: url)
    }

    if flushed { return }

    // Wait for AppKit to finish launching so state restoration has
    // had time to bring back document windows. If any are alive,
    // there's nothing for the FTUE picker to do.
    while !appDelegate.didFinishLaunching {
      try? await Task.sleep(for: .milliseconds(50))
      if Task.isCancelled { return }
    }

    // Settle: if `application(_:open:)` fired a URL into the now-
    // installed openHandler during this task, a doc window may still
    // be attaching. Give it a moment.
    try? await Task.sleep(for: .milliseconds(150))
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
