import Foundation

/// Strategy for handling an "open this file" request from Finder, the
/// open panel, or Open Recent when at least one Viewer window is
/// already up. With no existing windows, every behavior collapses to
/// "open a new window."
public enum OpenBehavior: String, CaseIterable, Identifiable, Sendable {
  /// Always spawn a fresh window.
  case newWindow
  /// Spawn a fresh window and merge it as a tab into the frontmost
  /// existing window (so the user ends up with a tab strip).
  case newTab
  /// Reuse the frontmost window — rebind it to the new document
  /// instead of creating another window.
  case replaceCurrent

  public var id: String { rawValue }

  /// Localized label for the case, exposed as
  /// `LocalizedStringResource` so the routing layer stays free of
  /// any UI framework dependency. Call sites resolve via
  /// `Text(behavior.displayName)` (SwiftUI) or
  /// `String(localized: behavior.displayName)` (everywhere else).
  public var displayName: LocalizedStringResource {
    switch self {
    case .newWindow: return "New Window"
    case .newTab: return "New Tab in Frontmost Window"
    case .replaceCurrent: return "Replace Frontmost Document"
    }
  }
}
