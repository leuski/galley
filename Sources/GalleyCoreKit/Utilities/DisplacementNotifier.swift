//
//  DisplacementNotifier.swift
//  GalleyKit
//

import Foundation
import UserNotifications

/// Posts user-facing notifications when a previously-selected
/// processor or template is no longer available and we've snapped
/// back to the default. Stateless — call `post(...)` whenever a
/// `healIfDisplaced()` returns non-nil.
public enum DisplacementNotifier {
  /// Ask for notification authorization. Safe to call repeatedly —
  /// the system records the user's first answer. Errors are
  /// swallowed; the notification post will simply do nothing if not
  /// authorized.
  public static func requestAuthorization() async {
    let center = UNUserNotificationCenter.current()
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  public enum Kind: Sendable {
    case processor
    case template

    /// Localized notification title for the case, exposed as
    /// `LocalizedStringResource` for symmetry with the rest of the
    /// kit. Full phrase per case (rather than `"\(thing) unavailable"`)
    /// so translators can re-arrange word order — "Template" +
    /// " unavailable" is not a safe word-by-word concatenation in
    /// many languages. The notifier resolves to `String` at the
    /// `UNNotificationContent.title` boundary.
    public var title: LocalizedStringResource {
      switch self {
      case .processor: LocalizedStringResource(
        "Markdown processor unavailable", bundle: .galleyCoreKit)
      case .template: LocalizedStringResource(
        "Template unavailable", bundle: .galleyCoreKit)
      }
    }
  }

  public static func post(kind: Kind, displaced: String) {
    Task { await _post(kind: kind, displaced: displaced) }
  }

  /// Post a "<thing> unavailable" notification. The display name is
  /// what the user previously picked; we already healed the
  /// selection by the time this is called.
  ///
  /// `UNMutableNotificationContent.title` / `.body` are `String`-typed,
  /// so we resolve through `String(localized:)` here at the boundary.
  /// The body uses interpolation, which `String.LocalizationValue`
  /// captures as a `%@` placeholder in the strings catalog —
  /// translators receive
  /// `"%@ is no longer available — switched to the default."` as one
  /// key with the displaced name as the runtime substitution.
  private static func _post(kind: Kind, displaced: String) async {
    let content = UNMutableNotificationContent()
    content.title = String(localized: kind.title)
    content.body = String(
      localized:
        "\(displaced) is no longer available — switched to the default.",
      bundle: .galleyCoreKit)
    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil)
    _ = try? await UNUserNotificationCenter.current().add(request)
  }
}
