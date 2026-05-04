import Foundation
import os

private let log = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

/// Cross-process bridge for the shared preferences suite.
/// `UserDefaults.didChangeNotification` is process-local (Apple:
/// "There is no broadcast to other applications"), so the
/// `@ObservableDefaults` macro's observer in a peer process never
/// wakes up on its own — even though `cfprefsd` does invalidate the
/// peer's cache, the *notification* doesn't cross. Without this
/// bridge, picks made in one app surface in the other only by
/// accident (when something else in the peer happens to write to
/// any UserDefaults instance, firing the local notification, which
/// makes the macro observer re-read and incidentally see the
/// already-cache-fresh value).
///
/// Mechanism: a single Darwin notification name. Writers call
/// `post()` after a tracked write; listeners (registered once via
/// `startListening()`) translate every received Darwin notification
/// into a local `UserDefaults.didChangeNotification` post on
/// `NotificationCenter.default`, which is exactly what
/// ObservableDefaults' generated observer subscribes to.
///
/// Loop safety: when the listener triggers a re-read that updates
/// `choice.selected`, `bindPersistent`'s outbound observer compares
/// `read()` to the new value and short-circuits — no echo write, no
/// echo broadcast.
public enum DefaultsBroadcast {
  /// Darwin notification name. Process-global, so prefix with the
  /// app suite to avoid colliding with anything else on the system.
  public static let darwinNotificationName: String
    = "net.leuski.galley.preferences-did-change"

  /// Idempotent registration of the Darwin observer. Safe to call
  /// from both apps' boot paths; subsequent calls are no-ops.
  @MainActor
  public static func startListening() {
    guard !didStart else { return }
    didStart = true
    let pid = ProcessInfo.processInfo.processIdentifier
    log.notice("DefaultsBroadcast.startListening pid=\(pid)")
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = CFNotificationName(
      rawValue: darwinNotificationName as CFString)
    CFNotificationCenterAddObserver(
      center,
      nil,
      { _, _, _, _, _ in
        // Hop to the main queue: ObservableDefaults schedules its
        // observer on `.main`, and the @Observable host is main-
        // actor isolated.
        let pid = ProcessInfo.processInfo.processIdentifier
        log.debug("DefaultsBroadcast received pid=\(pid)")
        DispatchQueue.main.async {
          NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification, object: nil)
        }
      },
      name.rawValue,
      nil,
      .deliverImmediately)
  }

  /// Notify all subscribed processes (including this one — harmless
  /// thanks to the dedup in `bindPersistent`) that a tracked
  /// preference has changed. Call this immediately after a write to
  /// the shared suite.
  public static func post() {
    let pid = ProcessInfo.processInfo.processIdentifier
    log.debug("DefaultsBroadcast.post pid=\(pid)")
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let name = CFNotificationName(
      rawValue: darwinNotificationName as CFString)
    CFNotificationCenterPostNotification(
      center, name, nil, nil, true)
  }

  @MainActor private static var didStart = false
}
