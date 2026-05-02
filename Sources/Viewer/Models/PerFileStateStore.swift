import Foundation
import Observation
import os

/// Persisted view-state Galley remembers about each previously-seen
/// file. Survives window-close, app-quit, and fresh re-opens of the
/// same path. All fields are optional so "no value stored" is
/// distinguishable from "stored at default".
struct PerFileState: Codable, Equatable, Sendable {
  var pageZoom: Double?
  var scrollY: Double?
  var rendererPersistent: String?
  var templatePersistent: String?

  var isEmpty: Bool {
    pageZoom == nil
      && scrollY == nil
      && rendererPersistent == nil
      && templatePersistent == nil
  }
}

/// Stores `PerFileState` records keyed by the standardized file path,
/// so a fresh window opening "report.md" after a relaunch can hydrate
/// scroll position, zoom, and per-document override picks the user
/// last left it at.
///
/// `@SceneStorage` already handles the *window-restoration* case
/// (windows that were open at quit time come back with their state).
/// This store covers the *fresh open* case (file opened anew via
/// Finder, Open Recent, BBEdit script). When both kinds of state are
/// present, ContentView prefers `@SceneStorage` if it carries
/// non-default values — those represent the user's most recent
/// interaction with that specific window.
@MainActor
@Observable
final class PerFileStateStore {
  @ObservationIgnored
  private var cache: [String: PerFileState] = [:]

  @ObservationIgnored
  private let defaultsKey = "\(keyPrefix).perFileState"

  @ObservationIgnored
  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "PerFileStateStore")

  init() {
    cache = Self.load(key: defaultsKey, logger: logger)
  }

  /// Snapshot of stored state for `url`. Returns an empty record
  /// (all fields nil) when the file has never been seen.
  func state(for url: URL) -> PerFileState {
    cache[Self.key(for: url)] ?? PerFileState()
  }

  /// Apply a mutation and persist. The closure receives the existing
  /// state (or an empty record if there isn't one). When the result
  /// is empty the entry is removed entirely so the dictionary
  /// doesn't grow unbounded as users skim through many files.
  func update(
    _ url: URL,
    _ mutation: (inout PerFileState) -> Void
  ) {
    let key = Self.key(for: url)
    var state = cache[key] ?? PerFileState()
    mutation(&state)
    if state.isEmpty {
      cache.removeValue(forKey: key)
    } else {
      cache[key] = state
    }
    persist()
  }

  // MARK: - Private

  private static func key(for url: URL) -> String {
    url.resolvingSymlinksInPath().path
  }

  private static func load(
    key: String,
    logger: Logger
  ) -> [String: PerFileState] {
    guard let data = UserDefaults.standard.data(forKey: key) else {
      return [:]
    }
    do {
      return try JSONDecoder().decode(
        [String: PerFileState].self, from: data)
    } catch {
      logger.warning("""
        Discarding unreadable per-file state: \
        \(error.localizedDescription, privacy: .public)
        """)
      return [:]
    }
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(cache)
      UserDefaults.standard.set(data, forKey: defaultsKey)
    } catch {
      logger.error("""
        Failed to persist per-file state: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }
}
