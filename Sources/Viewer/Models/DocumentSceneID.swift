//
//  DocumentSceneID.swift
//  Galley
//

import Foundation

/// Stable per-window identity for the Viewer's document windows.
///
/// Viewer-local on purpose (deliberately **not** `KosmosCore.WindowID`):
/// a window's local identity is independent of the Mac↔AVP transport.
///
/// This is the `WindowGroup(for:)` value type. SwiftUI persists it per
/// window and hands it back on restore; the document a window shows is
/// looked up from `DocumentStore` by this id. The URL travels separately
/// (inbound activity URLs), the id travels with the window — see
/// `docs/rebuild-document-windowing.md`.
///
/// Mirrors Dot's `BrowserSceneID`. The `rawValue` is a UUID string so the
/// id doubles as a plist-safe dictionary key (`description`) for the
/// snapshot store.
struct DocumentSceneID: Hashable, Codable, Sendable, CustomStringConvertible {
  private let rawValue: String

  private init(rawValue: String) { self.rawValue = rawValue }

  var description: String { rawValue }

  /// Mint a fresh identity. Used by the `WindowGroup`'s `defaultValue:`
  /// so every window is born with a non-nil id — there is no nil-value
  /// bootstrap member (which is what made the old reveal path race).
  @MainActor static func next() -> Self { .init(rawValue: UUID().uuidString) }
}
