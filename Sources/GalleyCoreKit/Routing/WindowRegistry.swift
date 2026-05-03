import Foundation

/// Opaque identity for a viewer window. The router and registry only
/// care about identity equality, never the underlying object — so we
/// wrap an explicit `UInt64` rather than an `ObjectIdentifier`.
///
/// Why not `ObjectIdentifier(NSWindow)`? It is just a wrapped pointer.
/// In tests, a `StubWindow()` temporary is freed as soon as it leaves
/// the local scope; the next allocation may reuse the address, and
/// two different `WindowID(StubWindow())` calls then compare equal.
/// The production caller (`ViewerAppDelegate`) holds the `NSWindow`
/// alive in a registry, but the value-type `WindowID` itself must not
/// require the AnyObject to stay alive — otherwise tests turn flaky
/// the moment they introduce a temporary.
///
/// Production callers mint IDs through `WindowIDAllocator` (see
/// below) and key their own `[ObjectIdentifier: WindowID]` table off
/// the live `NSWindow`.
public struct WindowID: Hashable, Sendable, CustomStringConvertible {
  public let raw: UInt64

  public init(raw: UInt64) {
    self.raw = raw
  }

  public var description: String {
    "WindowID(\(raw))"
  }
}

/// Monotonic allocator for `WindowID`s. Each new window gets a fresh
/// integer that never collides with a previously-issued one within
/// the lifetime of the allocator. The Viewer's `ViewerAppDelegate`
/// owns a single allocator and consults it once per `registerWindow`
/// call, then maps `NSWindow → WindowID` in its own table for
/// subsequent lookups.
public struct WindowIDAllocator: Sendable {
  private var counter: UInt64 = 0

  public init() {}

  public mutating func next() -> WindowID {
    counter &+= 1
    return WindowID(raw: counter)
  }
}

/// Snapshot of one registered window's state. Value-type so the
/// registry can hand out copies for routing decisions without leaking
/// the underlying `NSWindow` reference.
///
/// Every registered window is a document window — the welcome scene
/// (the launch-time bootstrap anchor) lives in a separate SwiftUI
/// scene and is never registered here. There is no placeholder
/// concept in the routing layer.
public struct WindowRecord: Hashable, Sendable {
  public let id: WindowID
  public var currentURL: URL?

  public init(id: WindowID, currentURL: URL? = nil) {
    self.id = id
    self.currentURL = currentURL
  }
}

/// Pure value-type collection of `WindowRecord`s keyed by `WindowID`.
/// Owns the rules for "which window is the frontmost?" and "is this
/// URL already open somewhere?". The Viewer's AppKit adapter mirrors
/// `NSWindow` register/unregister events into mutations on this
/// struct, then asks the router to decide what to do with an
/// inbound URL.
///
/// Frontmost lookups take an explicit `mainWindow` and `keyWindow`
/// hint (passed in by the adapter from `NSApp.mainWindow` /
/// `NSApp.keyWindow`) so the registry stays platform-agnostic.
public struct WindowRegistry: Sendable {
  private var records: [WindowID: WindowRecord] = [:]

  public init() {}

  public var all: [WindowRecord] { Array(records.values) }
  public var isEmpty: Bool { records.isEmpty }

  public func record(for id: WindowID) -> WindowRecord? {
    records[id]
  }

  public mutating func register(_ record: WindowRecord) {
    records[record.id] = record
  }

  public mutating func unregister(_ id: WindowID) {
    records.removeValue(forKey: id)
  }

  public mutating func updateCurrentURL(_ id: WindowID, _ url: URL?) {
    if var record = records[id] {
      record.currentURL = url
      records[id] = record
    }
  }

  /// First record whose `currentURL` matches `url` by standardized
  /// file path. Used to detect "this URL is already open in some
  /// window" before falling back to spawn.
  public func registration(matching url: URL) -> WindowRecord? {
    let target = url.standardizedFileURL.path
    return records.values.first { record in
      guard let bound = record.currentURL?.standardizedFileURL.path
      else { return false }
      return bound == target
    }
  }

  /// Pick the registration that should receive the next "replace" or
  /// "tab onto" request. Prefers the caller's `mainWindow` hint,
  /// then `keyWindow`, then any registered window.
  public func frontmost(
    mainWindow: WindowID? = nil,
    keyWindow: WindowID? = nil
  ) -> WindowRecord? {
    for hint in [mainWindow, keyWindow].compactMap({ $0 }) {
      if let record = records[hint] { return record }
    }
    return records.values.first
  }
}
