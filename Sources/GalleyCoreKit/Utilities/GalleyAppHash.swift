import CryptoKit
import Foundation

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

  static func computeSync(at root: URL) throws -> String {
    let manager = FileManager.default
    let rootPath = root.standardizedFileURL.path
    guard manager.fileExists(atPath: rootPath) else {
      throw CocoaError(.fileNoSuchFile)
    }

    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = manager.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [])
    else {
      throw CocoaError(.fileReadUnknown)
    }

    var entries: [(relativePath: String, url: URL)] = []
    for case let url as URL in enumerator {
      let isFile = (try? url.resourceValues(
        forKeys: [.isRegularFileKey]).isRegularFile) ?? false
      guard isFile else { continue }
      let absolute = url.standardizedFileURL.path
      let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
      let relative = absolute.hasPrefix(prefix)
        ? String(absolute.dropFirst(prefix.count))
        : absolute
      entries.append((relative, url))
    }
    entries.sort { $0.relativePath < $1.relativePath }

    var hasher = SHA256()
    let separator = Data([0])
    for entry in entries {
      hasher.update(data: Data(entry.relativePath.utf8))
      hasher.update(data: separator)
      let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
      hasher.update(data: data)
      hasher.update(data: separator)
    }
    return hasher.finalize()
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
