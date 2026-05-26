import Foundation
@_exported import KosmosCore

// `WindowID` and `WindowIDAllocator` come from `KosmosCore` and are
// re-exported above. The same identifier flows across the Mac↔AVP
// wire (in `OpenDocument` / `CloseWindow` / `WindowContentChanged`)
// and is keyed locally by the Mac Viewer's `WindowDispatcher` — one
// type for both roles. Production callers mint IDs through
// `WindowIDAllocator` (a class with internal locking) and key their
// own `[ObjectIdentifier: WindowID]` table off the live `NSWindow`.

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
