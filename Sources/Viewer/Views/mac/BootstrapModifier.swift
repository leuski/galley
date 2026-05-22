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
  @Environment(AppBoot.self) private var boot
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content
      .task {
        let action = openWindow
        dispatcher.install { url in
          action(value: url)
        }
        // Help URLs route to the singleton "help" scene. The
        // dispatcher writes `currentHelpURL` before invoking this
        // handler so the help window's content view observes the
        // value before SwiftUI mounts/raises the window.
        dispatcher.installHelp {
          action(id: "help")
        }
      }
      .onOpenURL { url in
        // Settings via galley:// scheme: the dispatcher hands the
        // outcome back via `onSettingsRequested`. `NSApp.activate`
        // is async on macOS 14+, so if we open Settings first the
        // previously-key doc window resurfaces on top of it once
        // activation completes. Activate, then open Settings, then
        // raise the Settings window on the next run-loop turn so it
        // wins over whatever activation brought forward.
        dispatcher.handleOpenURLs([url]) { tab in
          if let tab { boot.model?.selectedSettingsTab = tab }
          NSApp.activate(ignoringOtherApps: true)
          openSettings()
          Task { @MainActor in
            NSApp.windows
              .first { $0.identifier?.rawValue
                .lowercased().contains("settings") == true }?
              .makeKeyAndOrderFront(nil)
          }
        }
        switch url.galleyRequest {
        case .openSettings:
          break
        case .document(let info):
          recents.record(info.url)
        case .none:
          recents.record(url)
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
