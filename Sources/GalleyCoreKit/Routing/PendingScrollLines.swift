import Foundation

/// Keyed cache of "scroll to line N when this URL eventually binds."
/// Populated when a `galley://path?line=N` URL arrives — the Viewer's
/// adapter normalizes it to a plain `file://` URL and stashes the
/// line here. ContentView consumes the entry at bind time.
///
/// Keyed by standardized file path string rather than `URL` because
/// `URL` Hashable equality is sensitive to encoding/symlink/trailing
/// slash differences between the URL we construct and whatever URL
/// SwiftUI hands back through the WindowGroup binding.
public struct PendingScrollLines: Sendable, Equatable {
  private var lines: [String: Int] = [:]

  public init() {}

  public var isEmpty: Bool { lines.isEmpty }

  public mutating func stash(_ line: Int, for url: URL) {
    lines[Self.key(for: url)] = line
  }

  /// Take and clear the pending line for `url`, if any.
  public mutating func consume(for url: URL) -> Int? {
    lines.removeValue(forKey: Self.key(for: url))
  }

  /// Inspect without consuming — used by tests and diagnostic output.
  public func peek(for url: URL) -> Int? {
    lines[Self.key(for: url)]
  }

  private static func key(for url: URL) -> String {
    url.standardizedFileURL.path
  }
}
