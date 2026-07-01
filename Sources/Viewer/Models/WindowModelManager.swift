//
//  WindowModelManager.swift
//  Galley
//
//  Created by Anton Leuski on 7/1/26.
//

import GalleyCoreKit

final class WindowModelManager: PersistentModelManager<
DocumentSceneID, DocumentModel>
{
  static let shared = WindowModelManager()

  init() {
    super.init(store: KeyedStoreImpl(
      getter: { id in Defaults.shared[snapshot: id] },
      setter: { id, value in
        Defaults.shared[snapshot: id] = value
        guard let value else { return }
        Defaults.shared[snapshot: value.currentURL] = value.droppingHistory
      }))
  }

  /// Live-or-restored model for a window. Returns `nil` when the window
  /// has no stored document (the welcome state). Synchronous — safe to
  /// call from a `@State` initial value.
  func forScene(id: DocumentSceneID) -> DocumentModel? {
    get(for: id)
  }

  /// Bind an inbound document to a window, building the model if the
  /// window was empty (welcome → document, in place) and caching it.
  /// A fresh window seeds its view-state (zoom/scroll/TOC/choices) from
  /// the file store so reopening a known file restores where you were.
  func open(
    target: DocumentTarget, id: DocumentSceneID) -> DocumentModel
  {
    if let existing = existing(for: id) { return existing }
    var snapshot = Defaults.shared[snapshot: target.documentURL]
    ?? DocumentModel.Snapshot(url: target.documentURL)
    if let scroll = target.scroll {
      snapshot.scroll = scroll
    }
    return remember(DocumentModel(snapshot: snapshot), for: id)
  }
}
