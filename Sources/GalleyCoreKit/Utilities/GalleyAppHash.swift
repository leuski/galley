import CryptoKit
import Foundation
import ALFoundation

/// Identity check for the Viewer ↔ Server contract. Both apps embed
/// the same `GalleyCoreKit` framework binary, the same
/// `Templates.bundle` resources, and assume the same Choice
/// serialization shape. When the running Server is from an older
/// install than the Viewer (or vice versa), defaults writes from one
/// process get clobbered by the other's reconcile() — the symptom
/// looks like "the user can't change templates" because the smaller
/// catalog wins the round-trip.
///
/// `compute(at:)` produces a SHA256 over the recursive contents of an
/// app bundle on disk. The Server publishes its bundle's hash on
/// launch; the Viewer compares its own hash on launch and restarts
/// the Server when they differ.
public enum GalleyAppHash {
  /// SHA256 over every regular file under `root`, in sorted-relative-
  /// path order, with each file's content prefixed by its relative
  /// path (and a NUL separator) so the hash detects renames as well
  /// as content changes. `mappedIfSafe` keeps memory low for the
  /// embedded mermaid bundle.
  public static func compute(at root: URL) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      try Self.computeSync(at: root)
    }.value
  }

  static let separator = Data([0])

  static func computeSync(at root: URL) throws -> String {
    try root.enumerator(
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.producesRelativePathURLs])
    .filter(\.isRegularFile)
    .map { url in (relativePath: url.relativePath, url: url) }
    .sorted { $0.relativePath < $1.relativePath }
    .reduce(into: SHA256()) { hasher, entry in
      hasher.update(data: Data(entry.relativePath.utf8))
      hasher.update(data: Self.separator)
      let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
      hasher.update(data: data)
      hasher.update(data: Self.separator)
    }
    .finalize()
    .map { String(format: "%02x", $0) }
    .joined()
  }
}
