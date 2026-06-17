//
//  DocumentModel+Snapshot.swift
//  Galley
//

import Foundation
import GalleyCoreKit
import KosmosAppKit

extension DocumentModel {
  /// The single persistent shape for a document window: the nav stack
  /// plus per-file view state (scroll, zoom, TOC, choice overrides).
  /// Stored in `DocumentStore`, keyed by window id and, for windowless
  /// URLs, by file url. See `docs/rebuild-document-windowing.md`.
  ///
  /// Every field after `history`/`currentIndex` defaults to "unset" so a
  /// blank window (welcome) round-trips as an empty snapshot.
  struct Snapshot: Codable, Hashable, Sendable {
    /// Back/forward stack in visit order. Empty == no document.
    var history: [URL] = []
    /// Index of the currently-shown entry within `history`.
    var currentIndex: Int = 0
    /// Resting scroll position of the current page; `nil` == top.
    var scrollY: Double?
    /// TOC sidebar visibility; `nil` == platform default.
    var showsTOC: Bool?
    /// Page zoom factor; `nil` == 1.0.
    var pageZoom: Double?
    /// Per-window template override (`Template.persistentID`).
    var templatePersistent: String?
    /// Per-window renderer override (`Processor.persistentID`).
    var rendererPersistent: String?
    /// Per-window color-scheme override (visionOS).
    var colorSchemePersistent: String?
    /// visionOS: lets a fresh window re-resolve a sandboxed file URL.
    var securityScopedBookmark: Data?

    /// The entry the window is currently showing, or `nil` for a blank
    /// window or an out-of-range index (format drift degrades, not traps).
    var currentURL: URL? {
      history.indices.contains(currentIndex) ? history[currentIndex] : nil
    }

    var hasDocument: Bool { currentURL != nil }
  }

  /// Collect the model's current persistent state into a `Snapshot`.
  ///
  /// `currentScrollY` is read here even though it's `@ObservationIgnored`
  /// — scroll churn must never *trigger* a save (see the model's
  /// persistence observer), but the resting position is captured when
  /// some other durable field does fire one.
  var snapshot: Snapshot {
    Snapshot(
      history: history,
      currentIndex: currentIndex,
      scrollY: currentScrollY == 0 ? nil : currentScrollY,
      showsTOC: showsTOC,
      pageZoom: zoomFactorIfNonDefault,
      templatePersistent: templates.persistent,
      rendererPersistent: processors.persistent,
      colorSchemePersistent: colorSchemes.persistent,
      securityScopedBookmark: nil)
  }

  /// A single-file projection — what gets stored under the file-url key
  /// so a later fresh window re-seeds this file's view state. The nav
  /// stack collapses to the one file.
  func fileSnapshot(for url: URL) -> Snapshot {
    var projection = snapshot
    projection.history = [url]
    projection.currentIndex = 0
    return projection
  }

  /// Zoom factor, or `nil` when at the 1.0 default / not yet initialized
  /// (the controller seeds `0` before the first `setZoom`).
  private var zoomFactorIfNonDefault: Double? {
    let scale = zoom.zoomScale
    return (scale == 0 || scale == 1) ? nil : scale
  }
}

// MARK: - Per-scene instance cache + factories

extension DocumentModel {
  private final class WeakRef {
    weak var model: DocumentModel?
    init(_ model: DocumentModel) { self.model = model }
  }

  /// SwiftUI re-creates a window's content view on every parent/scene
  /// body pass, and `@State`'s initial value is evaluated eagerly each
  /// time — so a bare `DocumentModel(...)` there would be built and
  /// discarded repeatedly (a `WebPage` + bridges + render each time).
  /// Dedup by window id; the strong owner is the scene's `@State`, so
  /// the model lives exactly as long as its window and is freed when
  /// SwiftUI tears the window down. Empty boxes are swept on lookup.
  private static var cache: [DocumentSceneID: WeakRef] = [:]

  private static func cached(_ id: DocumentSceneID) -> DocumentModel? {
    cache[id]?.model
  }

  private static func remember(_ model: DocumentModel) {
    cache[model.id] = WeakRef(model)
    cache = cache.filter { $0.value.model != nil }
  }

  /// Live-or-restored model for a window. Returns `nil` when the window
  /// has no stored document (the welcome state). Synchronous — safe to
  /// call from a `@State` initial value.
  static func forScene(
    id: DocumentSceneID, appModel: AppModel
  ) -> DocumentModel? {
    if let existing = cached(id) { return existing }
    guard let snapshot = DocumentStore[id], snapshot.hasDocument else {
      return nil
    }
    let model = DocumentModel(snapshot: snapshot, id: id, appModel: appModel)
    remember(model)
    return model
  }

  /// Bind an inbound document to a window, building the model if the
  /// window was empty (welcome → document, in place) and caching it.
  /// A fresh window seeds its view-state (zoom/scroll/TOC/choices) from
  /// the file store so reopening a known file restores where you were.
  @discardableResult
  static func open(
    target: DocumentTarget, id: DocumentSceneID, appModel: AppModel
  ) -> DocumentModel {
    if let existing = cached(id) { return existing }
    var seed = DocumentStore[file: target.documentURL]
    let model = DocumentModel(
      id: id,
      appModel: appModel,
      history: [target.documentURL],
      currentIndex: 0,
      templatePersistent: seed?.templatePersistent,
      processorPersistent: seed?.rendererPersistent,
      colorSchemePersistent: seed?.colorSchemePersistent,
      initialScrollY: seed?.scrollY,
      initialScrollLine: target.scrollLine,
      initialShowsTOC: seed?.showsTOC ?? false,
      initialZoom: seed?.pageZoom ?? 1,
      kind: .document)
    remember(model)
    return model
  }

  /// The singleton Help window's model — a bundled file, never
  /// persisted (`kind: .help` skips the persistence observer).
  static func help(url: URL, appModel: AppModel) -> DocumentModel {
    DocumentModel(
      id: .next(), appModel: appModel, history: [url], kind: .help)
  }

  /// Construct from a restored snapshot.
  convenience init(
    snapshot: Snapshot, id: DocumentSceneID, appModel: AppModel
  ) {
    self.init(
      id: id,
      appModel: appModel,
      history: snapshot.history,
      currentIndex: snapshot.currentIndex,
      templatePersistent: snapshot.templatePersistent,
      processorPersistent: snapshot.rendererPersistent,
      colorSchemePersistent: snapshot.colorSchemePersistent,
      initialScrollY: snapshot.scrollY,
      initialShowsTOC: snapshot.showsTOC ?? false,
      initialZoom: snapshot.pageZoom ?? 1,
      kind: .document)
  }
}

// MARK: - Explicit model → store persistence (no view mediation)

extension DocumentModel {
  /// Arm the persistence observer. The model owns its own persistence —
  /// no view observes the model to write the store (see
  /// `feedback_no_view_mediated_model_mutation`). The tracked set is the
  /// durable fields; any change writes the snapshot to `DocumentStore`
  /// (both the window-keyed and file-keyed halves).
  func startTrackingPersistentState() {
    saveObservation = onObservedChange(
      track: { [weak self] in
        guard let self else { return }
        _ = self.history
        _ = self.currentIndex
        _ = self.showsTOC
        _ = self.templates.persistent
        _ = self.processors.persistent
        _ = self.colorSchemes.persistent
        _ = self.zoom.zoomScale
        _ = self.renderedTemplateID
        _ = self.currentScrollY
      },
      onChange: { [weak self] in self?.save() })
  }

  private func save() {
    let snapshot = self.snapshot
    DocumentStore[id] = snapshot
    if let url = snapshot.currentURL {
      DocumentStore[file: url] = fileSnapshot(for: url)
    }
  }

  /// Re-render when a render input changes: the global processor /
  /// template selection, the per-document-override toggle, or this
  /// window's own per-window choice overrides. Explicit model wiring —
  /// replaces the old `ChangeHandlers` `.onChange(of: appModel.…)` that
  /// had the view observe the app model to drive this model's reload.
  func startTrackingRenderInputs() {
    reloadObservation = onObservedChange(
      track: { [weak self] in
        guard let self else { return }
        _ = self.appModel.processors.selected
        _ = self.appModel.templates.selected
        _ = Defaults.shared.enablePerDocumentOverrides
        _ = self.templates.persistent
        _ = self.processors.persistent
        _ = self.colorSchemes.persistent
      },
      onChange: { [weak self] in
        Task { await self?.reload() }
      })
  }
}
