//
//  WindowModelManager.swift
//  Galley
//
//  Created by Anton Leuski on 7/1/26.
//

import GalleyCoreKit
import Foundation

@MainActor
final class WindowModelManager: @MainActor PersistentModelManager<
DocumentSceneID, WindowModel>
{
  let appModel: AppModel
  let storeDecoder: JSONDecoder

  var persistentModelCache = PersistentModelCache<ID, Value>()

  init (appModel: AppModel) {
    self.appModel = appModel
    let decoder = JSONDecoder()
    decoder.userInfo[.appModel] = appModel
    self.storeDecoder = decoder
  }

  /// Live-or-restored model for a window. Returns `nil` when the window
  /// has no stored document (the welcome state). Synchronous — safe to
  /// call from a `@State` initial value.
  func forScene(id: DocumentSceneID) -> WindowModel? {
    find(for: id)
  }

  subscript (snapshot id: ID) -> Data? {
    get { Defaults.shared[snapshot: id] }
    set { Defaults.shared[snapshot: id] = newValue }
  }

  public func save(_ model: Value, for key: ID) {
    self[store: key] = model
    model.tabs.forEach { tab in
      let tab = tab.snapshot
      Defaults.shared[snapshot: tab.currentURL] = tab.droppingHistory
    }
  }

  /// Bind an inbound document to a window, building the model if the
  /// window was empty (welcome → document, in place) and caching it.
  /// A fresh window seeds its view-state (zoom/scroll/TOC/choices) from
  /// the file store so reopening a known file restores where you were.
  func open(
    target: DocumentTarget, id: DocumentSceneID) -> WindowModel
  {
    findOrMake(for: id, make: WindowModel(makeTab(for: target)))
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
    let documentModel = DocumentModel(appModel: appModel, snapshot: snapshot)
    documentModel.lastRequest = target
    return documentModel
  }
}

typealias WindowModel = AbstractWindowModel<DocumentModel>
