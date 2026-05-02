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

  public enum Kind: String, Sendable {
    case processor = "Markdown processor"
    case template = "Template"
  }

  /// Post a "<thing> unavailable" notification. The display name is
  /// what the user previously picked; we already healed the
  /// selection by the time this is called.
  public static func post(kind: Kind, displaced: String) async {
    let content = UNMutableNotificationContent()
    content.title = "\(kind.rawValue) unavailable"
    content.body = """
      \(displaced) is no longer available — switched to the default.
      """
    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil)
    _ = try? await UNUserNotificationCenter.current().add(request)
  }
}
