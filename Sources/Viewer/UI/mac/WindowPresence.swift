//
//  WindowPresence.swift
//  Galley
//

#if os(macOS)
import AppKit
import Observation

/// Observable stand-in for AppKit's window list.
///
/// The File menu's Close / Close All decide their enabled state from
/// `NSApp.mainWindow` / `NSApp.keyWindow` / `NSApp.windows` — plain
/// AppKit properties that SwiftUI has no way to observe. Without a
/// dependency to invalidate on, SwiftUI evaluated each item's
/// `isEnabled` closure exactly once, while the menu bar was first
/// built: at that point the app owns **zero** windows, so both items
/// were born disabled and never re-validated, for the whole session.
///
/// `revision` is that dependency. Reading it inside an `isEnabled`
/// closure registers the observation; bumping it on every window
/// lifecycle notification makes SwiftUI rebuild the item and re-read
/// the live `NSApp` state.
@Observable
@MainActor
final class WindowPresence {
  static let shared = WindowPresence()

  /// Opaque change counter — the value carries no meaning, only its
  /// mutation does. Read it to observe the window set.
  private(set) var revision = 0

  /// Notifications that bracket every change to "which windows can be
  /// closed": a window gaining or losing main/key status covers open
  /// and focus changes, and `willClose` covers teardown.
  private static let triggers: [Notification.Name] = [
    NSWindow.didBecomeMainNotification,
    NSWindow.didResignMainNotification,
    NSWindow.didBecomeKeyNotification,
    NSWindow.didResignKeyNotification,
    NSWindow.willCloseNotification
  ]

  @ObservationIgnored private var observers: [any NSObjectProtocol] = []

  private init() {
    observers = Self.triggers.map { name in
      NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleBump() }
      }
    }
  }

  /// Bump on the next main-actor turn rather than inline. `willClose`
  /// fires *before* the window leaves `NSApp.windows`, so an inline
  /// bump would re-validate against the pre-close list and leave Close
  /// enabled after the last window went away.
  private func scheduleBump() {
    Task { @MainActor in revision &+= 1 }
  }
}
#endif
