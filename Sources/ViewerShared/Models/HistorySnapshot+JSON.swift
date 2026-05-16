import Foundation

/// JSON-string adapter on `HistorySnapshot` for `@SceneStorage`.
/// SwiftUI's scene storage hands us a `String`; the stored shape is
/// the JSON-encoded snapshot, written at every history mutation and
/// decoded on launch.
///
/// Both directions are tolerant: encode returns nil only on a
/// (currently impossible) Codable failure; decode treats empty
/// string, undecodable JSON, and an empty `urls` array as "no
/// snapshot" so a corrupted store can't crash launch.
extension HistorySnapshot {
  /// Encode the snapshot for `@SceneStorage`. Returns nil only on
  /// encoder failure — which would imply a non-Codable URL,
  /// currently impossible with `Foundation.URL`.
  func encodedAsJSON() -> String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Decode a previously-stored snapshot from `@SceneStorage`.
  /// Returns nil for any of: empty string (default initial state),
  /// undecodable JSON (corrupt or schema-incompatible store), or
  /// empty `urls` array (semantically equivalent to "no snapshot").
  static func decode(json text: String) -> HistorySnapshot? {
    guard !text.isEmpty,
          let data = text.data(using: .utf8),
          let snapshot = try? JSONDecoder().decode(
            HistorySnapshot.self, from: data),
          !snapshot.urls.isEmpty
    else { return nil }
    return snapshot
  }
}
