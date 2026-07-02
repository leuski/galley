//
//  WindowModelManager.swift
//  Galley
//
//  Created by Anton Leuski on 7/1/26.
//

import GalleyCoreKit

final class WindowModelManager: PersistentModelManager<
DocumentSceneID, WindowModel>
{
  static let shared = WindowModelManager()

  init() {
    super.init(store: KeyedStoreImpl(
      getter: { id in Defaults.shared[snapshot: id] },
      setter: { id, value in
        Defaults.shared[snapshot: id] = value
        guard let value else { return }
        value.tabs.forEach { tab in
          Defaults.shared[snapshot: tab.currentURL] = tab.droppingHistory
        }
      }))
  }

  /// Live-or-restored model for a window. Returns `nil` when the window
  /// has no stored document (the welcome state). Synchronous — safe to
  /// call from a `@State` initial value.
  func forScene(id: DocumentSceneID) -> WindowModel? {
    get(for: id)
  }

  /// Bind an inbound document to a window, building the model if the
  /// window was empty (welcome → document, in place) and caching it.
  /// A fresh window seeds its view-state (zoom/scroll/TOC/choices) from
  /// the file store so reopening a known file restores where you were.
  func open(
    target: DocumentTarget, id: DocumentSceneID) -> WindowModel
  {
    if let existing = existing(for: id) { return existing }
    return remember(WindowModel(makeTab(for: target)), for: id)
  }

  /// Build a document tab seeded from the file store (so reopening a
  /// known file restores its zoom/scroll/TOC/choices) and stamped with
  /// the originating request. Shared by the welcome→document adopt path
  /// (`open`) and the visionOS new-tab path (`WindowModel.addTab`).
  func makeTab(for target: DocumentTarget) -> DocumentModel {
    var snapshot = Defaults.shared[snapshot: target.documentURL]
    ?? DocumentModel.Snapshot(url: target.documentURL)
    if let scroll = target.scroll {
      snapshot.scroll = scroll
    }
    let documentModel = DocumentModel(snapshot: snapshot)
    documentModel.lastRequest = target
    return documentModel
  }
}

typealias WindowModel = AbstractWindowModel<DocumentModel>
