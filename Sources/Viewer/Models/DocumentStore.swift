//
//  DocumentStore.swift
//  Galley
//

import Foundation
import KosmosAppKit

/// The viewer's persisted document state, unifying the per-window and
/// per-file stores behind one `DocumentModel.Snapshot` type.
///
/// Defaults-backed (UserDefaults), exactly as Dot does it — restoration
/// survives relaunch without `@SceneStorage` (which is broken on
/// visionOS). The window-keyed half rehydrates a restored window; the
/// file-keyed half re-seeds a fresh window opening a known file. See
/// `docs/rebuild-document-windowing.md`.
@MainActor
enum DocumentStore {
  /// Per-window snapshot, keyed by window id. `nil` for a window that
  /// has never held a document (empty/welcome).
  static subscript(id: DocumentSceneID) -> DocumentModel.Snapshot? {
    get { Defaults.shared.windowSnapshots[id.description] }
    set { Defaults.shared.windowSnapshots[id.description] = newValue }
  }

  /// Drop a window's snapshot (window closed for good).
  static func forget(id: DocumentSceneID) {
    Defaults.shared.windowSnapshots[id.description] = nil
  }

  /// Per-file snapshot (the windowless store). `nil` when the file has
  /// never been opened. The nav stack collapses to the single file.
  static subscript(file url: URL) -> DocumentModel.Snapshot? {
    get { Defaults.shared.fileSnapshots[fileKey(url)] }
    set { Defaults.shared.fileSnapshots[fileKey(url)] = newValue }
  }

  /// Stable plist key for a URL: file URLs canonicalize (standardized +
  /// symlink-resolved) so two paths to the same file share state;
  /// remote URLs keep host + path (`safe.path()` would drop the host).
  private static func fileKey(_ url: URL) -> String {
    url.isFileURL ? url.safe.path() : url.absoluteString
  }
}
