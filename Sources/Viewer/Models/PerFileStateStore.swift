import Foundation
import Observation
import OSLog
import GalleyCoreKit
import KosmosAppKit

/// Persisted view-state Galley remembers about each previously-seen
/// file. Survives window-close, app-quit, and fresh re-opens of the
/// same path. All fields are optional so "no value stored" is
/// distinguishable from "stored at default".
struct PerFileState: Codable, Equatable, Sendable {
  var pageZoom: Double?
  var scrollY: Double?
  var rendererPersistent: String?
  var templatePersistent: String?
  var showsTOC: Bool?
  /// visionOS-only per-document color-scheme override. `nil` means
  /// "use the global default." Serialized form (same envelope as
  /// `templatePersistent`) so the scene's `SceneColorSchemeChoice`
  /// reads it directly. macOS never writes here — its presentation
  /// tracks the system appearance directly. The field stays in
  /// shared shape so Codable round-trips through the suite-shared
  /// plist remain stable across platforms.
  var colorSchemePersistent: String?

  var isEmpty: Bool {
    pageZoom == nil
      && scrollY == nil
      && rendererPersistent == nil
      && templatePersistent == nil
      && showsTOC == nil
      && colorSchemePersistent == nil
  }

  /// Keying strategy:
  /// - File URLs normalize through `safe` (standardized +
  ///   symlink-resolved) and use `.path()` so two windows opened on
  ///   the same on-disk file via different paths share state.
  /// - Remote URLs use `absoluteString` so host+path uniqueness is
  ///   preserved — `safe.path()` would drop the host and collide
  ///   across origins.
  static func key(for url: URL) -> String {
    if url.isFileURL {
      return url.safe.path()
    }
    return url.absoluteString
  }
}

/// Narrow URL-keyed view over the underlying `[String: PerFileState]`
/// dictionary. Lets call sites write `store[url].pageZoom = z` instead
/// of routing through the `PerFileState.key(for:)` helper at every
/// access. The on-disk shape stays a plist-friendly string-keyed
/// dictionary — the conversion happens here.
extension Dictionary where Key == String, Value == PerFileState {
  subscript(url: URL) -> PerFileState {
    get { self[PerFileState.key(for: url), default: .init()] }
    set { self[PerFileState.key(for: url)] = newValue }
  }
}
