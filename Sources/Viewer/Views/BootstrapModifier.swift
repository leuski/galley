import AppKit
import GalleyCoreKit
import SwiftUI

/// Centralizes the launch-time bootstrap work that has to run no
/// matter which scene actually mounts:
///
///   1. Capture `\.openWindow` and install it on the dispatcher so
///      Cmd+O, Open Recent, the tab bar "+" handler, and `galley://`
///      URL schemes can all spawn document windows.
///   2. Drain `LaunchURLBuffer` (any URLs queued before a view was
///      alive — `dispatcher.install` does this for us).
///   3. Host `.onOpenURL` so Finder dispatches, `NSWorkspace.open`,
///      and `galley://` URL handlers reach the dispatcher.
///
/// Originally this lived on `WelcomeView` alone. macOS 26 / SwiftUI
/// will not always spawn a `Window` scene at launch when state
/// restoration has already produced doc windows — the welcome
/// anchor silently never mounts, taking all three responsibilities
/// down with it. By attaching this modifier to both welcome AND
/// every doc window, whichever view actually mounts wires the app
/// up correctly. `dispatcher.install` is idempotent: subsequent
/// calls just re-capture the latest `openWindow` action.
///
/// Welcome retains exclusive ownership of the FTUE Open panel
/// (cold launch with no docs and no Finder URL) — and on that
/// launch path welcome IS guaranteed to mount, since there is no
/// state to compete with.
struct BootstrapDispatchModifier: ViewModifier {
  @Environment(WindowDispatcher.self) private var dispatcher
  @Environment(RecentDocumentsModel.self) private var recents
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content
      .task {
        let action = openWindow
        dispatcher.install { url in
          action(value: url)
        }
      }
      .onOpenURL { url in
        // Settings via galley:// scheme: the dispatcher hands the
        // outcome back via `onSettingsRequested` — we activate the
        // app first so the Settings window doesn't open behind
        // whatever app the user clicked from (e.g. the Server
        // menu bar).
        dispatcher.handleOpenURLs([url]) {
          NSApp.activate(ignoringOtherApps: true)
          openSettings()
        }
        switch URLNormalizer.normalize(url) {
        case .openSettings:
          break
        case .document(let fileURL, _):
          recents.record(fileURL)
        case .unparseable(let original):
          recents.record(original)
        }
      }
  }
}

extension View {
  /// Attach the launch-time dispatch wiring to this view. Safe to
  /// apply on multiple sibling views — `dispatcher.install` is
  /// idempotent and `.onOpenURL` is dispatched to a single target
  /// per URL by SwiftUI.
  func bootstrapDispatch() -> some View {
    modifier(BootstrapDispatchModifier())
  }
}
