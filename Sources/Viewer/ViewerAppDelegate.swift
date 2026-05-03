import AppKit
import GalleyCoreKit
import Observation
import SwiftUI

/// Thin AppKit bridge for the few hooks SwiftUI doesn't yet
/// natively cover. Routing/registry state lives in
/// `WindowDispatcher`; recent-document and Open-panel state lives
/// in `RecentDocumentsModel`. The delegate's only remaining
/// responsibilities are:
///
///   - Forwarding `application(_:open:)` callbacks to the
///     dispatcher (the only reliable AppKit entry point for
///     URLs that arrive before any SwiftUI view exists). Once
///     `.onOpenURL` proves reliable for cold-launch URLs, this
///     file goes away entirely.
///   - Exposing `didFinishLaunching` so the welcome scene's task
///     knows when to stop waiting on state restoration.
///   - Three default-equivalent hook overrides
///     (`applicationShouldOpenUntitledFile`,
///     `applicationSupportsSecureRestorableState`,
///     `applicationShouldTerminateAfterLastWindowClosed`) — kept
///     explicit for documentation, not because they're needed.
///   - Pre-seeding the dispatcher's launch buffer with the
///     `--seed-file` test-mode injection point.
@MainActor
@Observable
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
  /// Set by `ViewerApp.body` so `application(_:open:)` can route
  /// URLs through the same model the SwiftUI views use.
  @ObservationIgnored weak var dispatcher: WindowDispatcher?

  /// Set by `ViewerApp.body` so `application(_:open:)` can record
  /// inbound URLs as recent.
  @ObservationIgnored weak var recents: RecentDocumentsModel?

  /// Reference to the shared `AppModel`, set by `WelcomeView` so
  /// the dispatcher can consult `openBehavior` without a SwiftUI
  /// environment lookup.
  @ObservationIgnored weak var appModel: AppModel?

  /// Set true when AppKit signals launch is complete.
  private(set) var didFinishLaunching = false

  /// Parsed view of `CommandLine.arguments`. Tests pass injection
  /// flags (`--seed-file`); production launches pass none.
  @ObservationIgnored let launchArgs: LaunchArguments

  override init() {
    self.launchArgs = LaunchArguments.fromProcess()
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    if let seed = launchArgs.seedFile {
      dispatcher?.enqueueAtLaunch(seed)
    }
  }

  // application(_:open:) intentionally not implemented here.
  // SwiftUI's `.onOpenURL` on the always-alive WelcomeView catches
  // every URL the system delivers — Finder file dispatches, the
  // `galley://` scheme handler, NSWorkspace.open, dock drops. The
  // welcome scene calls `dispatcher.handleOpenURLs(...)` and
  // records the URL into `recents` directly. Owning the URL
  // intake there keeps the routing path in one place and removes
  // the chicken-and-egg between the AppDelegate and the SwiftUI
  // view tree.

  /// Returning false here is deliberate: the always-alive
  /// `Window("welcome")` scene defined in `ViewerApp` captures
  /// `openWindow` and hosts the FTUE Open panel. SwiftUI doesn't
  /// bridge `applicationShouldOpenUntitledFile` to value-driven
  /// `WindowGroup`s anyway.
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
    false
  }

  /// Opt in to secure state restoration so macOS persists the open
  /// windows (and SwiftUI persists their `@SceneStorage` payloads)
  /// across launches without warning about insecure coding.
  func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }

  /// Stay alive after the last window closes — the user can
  /// launch the open panel again from File > Open. (Default
  /// already, but leave explicit for documentation.)
  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }
}
