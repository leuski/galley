import Foundation
import Observation
import os
import GalleyCoreKit

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

  var isEmpty: Bool {
    pageZoom == nil
      && scrollY == nil
      && rendererPersistent == nil
      && templatePersistent == nil
      && showsTOC == nil
  }

  static func key(for url: URL) -> String {
    url.safe.path()
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
