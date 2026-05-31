#if os(macOS)
import AppKit

/// Minimal AppDelegate that exists for one reason only: to declare
/// support for secure state restoration. Per Apple's docs, since
/// macOS 12 you *must* implement
/// `applicationSupportsSecureRestorableState` and return true for
/// AppKit to write the saved-state directory at quit. Without it,
/// SwiftUI's `WindowGroup<URL>` windows are never persisted, and
/// the user's open documents are silently lost on relaunch.
///
/// SwiftUI provides no scene-level way to declare this, so we
/// reintroduce an `NSApplicationDelegateAdaptor` for this single
/// hook. URL receipt + routing live in `InboundURLHandler` (per
/// window) and the small shared `ViewerOpenModel`; recents in
/// `RecentDocumentsModel`; those stay out of here.
///
/// If you find yourself reaching for another method on this class,
/// reconsider — most candidates have SwiftUI equivalents (look at
/// `.onOpenURL`, `.handlesExternalEvents`, scenePhase) or have
/// correct defaults already.
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
  func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }
}
#endif
