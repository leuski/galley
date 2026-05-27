import Foundation
import KosmosCore

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
