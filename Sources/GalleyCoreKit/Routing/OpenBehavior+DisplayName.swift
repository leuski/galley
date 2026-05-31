import Foundation
// Re-exported so `import GalleyCoreKit` keeps surfacing KosmosCore
// symbols module-wide (`WindowID` / `WindowIDAllocator` / `OpenBehavior`
// for the Viewer, and `MIMETypes` for `WebKit/PreviewSchemeHandler`).
// This re-export previously lived on the now-deleted `OpenURLRouter`.
@_exported import KosmosCore

public extension OpenBehavior {
  /// Localized label for the case, exposed as
  /// `LocalizedStringResource` so the routing layer stays free of
  /// any UI framework dependency. Call sites resolve via
  /// `Text(behavior.displayName)` (SwiftUI) or
  /// `String(localized: behavior.displayName)` (everywhere else).
  var displayName: LocalizedStringResource {
    switch self {
    case .newWindow: LocalizedStringResource(
      "New Window", bundle: .galleyCoreKit)
    case .newTab: LocalizedStringResource(
      "New Tab in Frontmost Window", bundle: .galleyCoreKit)
    case .replaceCurrent: LocalizedStringResource(
      "Replace Frontmost Document", bundle: .galleyCoreKit)
    }
  }
}
