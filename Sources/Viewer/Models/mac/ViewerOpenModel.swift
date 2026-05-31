#if os(macOS)
import AppKit
import Foundation
import GalleyCoreKit
import Observation

/// Minimal shared state for the Viewer's URL-open path — what's left of
/// the old `WindowDispatcher` / `OpenURLCoordinator` stack after SwiftUI
/// took over window selection (`handlesExternalEvents`), dedup
/// (`openWindow(value:)` value identity + `preferring:`), and lifecycle.
///
/// It holds only the one thing SwiftUI can't carry for us: the pending
/// scroll-to-line for a soon-to-open document window. `openWindow(value:
/// URL)` carries only the URL, not the `?line=N`, so the inbound handler
/// stashes the line here and the new window's `DocumentView.launchTask`
/// consumes it. (Settings and Help route by their own schemes straight
/// to their scenes — see `InboundURLHandler` — so no help-URL state
/// lives here.)
///
/// `@Observable @MainActor`, injected via `.environment()`.
@MainActor
@Observable
final class ViewerOpenModel {
  @ObservationIgnored private var pendingScrolls = PendingScrollLines()

  /// Captured SwiftUI `openWindow(value:)` action, installed by the
  /// first window to mount. Used by the non-view callers that can't
  /// reach `@Environment(\.openWindow)`: the AppKit tab-bar "+" and
  /// the menu / recents open paths.
  @ObservationIgnored private var openWindowAction: ((URL) -> Void)?

  /// Capture the window-spawn action. Idempotent — re-capturing the
  /// latest action is fine.
  func install(openWindow: @escaping (URL) -> Void) {
    openWindowAction = openWindow
  }

  /// Stash a scroll-to-line for a document about to open in a fresh
  /// window. Keyed by URL; consumed once by that window.
  func stash(scrollLine: Int, for url: URL) {
    pendingScrolls.stash(scrollLine, for: url)
  }

  /// Take and clear the pending scroll-to-line for `url`, if any.
  func consumePendingScrollLine(for url: URL) -> Int? {
    pendingScrolls.consume(for: url)
  }

  /// Open `url` by routing it back through the app's own `onOpenURL`
  /// handler (fire-at-self). Keeps menu / recents / Help opens on the
  /// exact same path as Finder opens: one classifier, one dedup rule,
  /// one open-behavior switch. File URLs are sent in their `galley://`
  /// form (the scheme the running instance claims); other URLs pass
  /// through unchanged.
  func openViaSelf(_ url: URL) {
    let target = url.isFileURL
    ? OpenDocumentActivity(url: url).url
    : url
    NSWorkspace.shared.open(target)
  }

  /// Open `url` as a new tab in the key window's tab group, regardless
  /// of the user's open-behavior. Used by the AppKit tab-bar "+", whose
  /// intent is unambiguously "new tab here". Born-as-tab (no flash) via
  /// `allowsAutomaticWindowTabbing` (WindowProbe FINDINGS §9).
  func openAsTab(_ url: URL) {
    NSWindow.allowsAutomaticWindowTabbing = true
    openWindowAction?(url)
  }
}
#endif
