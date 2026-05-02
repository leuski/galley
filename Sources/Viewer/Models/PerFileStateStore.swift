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

  var isEmpty: Bool {
    pageZoom == nil
      && scrollY == nil
      && rendererPersistent == nil
      && templatePersistent == nil
  }

  static func key(for url: URL) -> String {
    url.safe.path()
  }
}
