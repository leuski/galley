import Foundation

/// Concrete action the Viewer's AppKit adapter should take in response
/// to an inbound URL. The router decides; the adapter executes.
public enum DispatchAction: Sendable, Equatable {
  /// Pre-launch — no SwiftUI handler is installed yet. Caller queues
  /// the URL in the `LaunchURLBuffer` and replays it on `install`.
  case queue
  /// Spawn a fresh window via `openWindow(value:)`.
  case openNew
  /// Bring the window with the given ID to front and rebind it in
  /// place to the inbound URL.
  case rebind(WindowID)
  /// Tab onto the host with the given ID — caller queues `host` in
  /// `pendingTabHosts`, then calls `openWindow(value:)`. The fresh
  /// window's `WindowAccessor` consumes the queued host and merges.
  case tabOnto(WindowID)
  /// The URL is already open in the given window — bring it to
  /// front and call its rebind closure (which detects the same-URL
  /// case and just scrolls without resetting history).
  case focusExisting(WindowID)
}

/// Pure decision function over the inbound URL plus a snapshot of
/// the current window registry. Replaces the imperative
/// `dispatch(_:)` body that used to live in `ViewerAppDelegate`.
///
/// Returning a `DispatchAction` (instead of doing the work directly)
/// keeps every routing decision testable without an `NSApplication`.
///
/// The registry only contains document windows (the welcome scene
/// is a separate SwiftUI scene and is never registered), so the
/// router has no placeholder fallback — every `frontmost` is a
/// real document.
public struct OpenURLRouter: Sendable {
  public init() {}

  public func decide(
    for url: URL,
    behavior: OpenBehavior,
    registry: WindowRegistry,
    handlerInstalled: Bool,
    mainWindow: WindowID? = nil,
    keyWindow: WindowID? = nil
  ) -> DispatchAction {
    guard handlerInstalled else { return .queue }

    if let match = registry.registration(matching: url) {
      return .focusExisting(match.id)
    }

    let frontDoc = registry.frontmost(
      mainWindow: mainWindow,
      keyWindow: keyWindow)

    switch behavior {
    case .newWindow:
      return .openNew

    case .newTab:
      if let frontDoc { return .tabOnto(frontDoc.id) }
      return .openNew

    case .replaceCurrent:
      if let frontDoc { return .rebind(frontDoc.id) }
      return .openNew
    }
  }
}
