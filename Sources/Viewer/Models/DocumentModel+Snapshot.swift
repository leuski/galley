//
//  DocumentModel+Snapshot.swift
//  Galley
//

import Foundation
import GalleyCoreKit

extension DocumentModel {
  /// The single persistent shape for a document window: the nav stack
  /// plus per-file view state (scroll, zoom, TOC, choice overrides).
  /// Stored in `DocumentStore`, keyed by window id and, for windowless
  /// URLs, by file url. See `docs/rebuild-document-windowing.md`.
  ///
  /// Every field after `history`/`currentIndex` defaults to "unset" so a
  /// blank window (welcome) round-trips as an empty snapshot.
  struct Snapshot: Codable {
    /// Back/forward stack in visit order.
    var history: History
    /// Resting scroll position of the current page.
    var scroll: Scroll = .top
    /// TOC sidebar visibility.
    var showsTOC: Bool = false
    /// Page zoom factor.
    var pageZoom: Double = 1.0
    /// Per-window template override (`Template.persistentID`).
    var templatePersistent: SceneTemplateChoice
      .PersistentSelectionRepresentation?
    /// Per-window renderer override (`Processor.persistentID`).
    var rendererPersistent: SceneProcessorChoice
      .PersistentSelectionRepresentation?
    /// Per-window color-scheme override (visionOS).
    var colorSchemePersistent: SceneColorSchemeChoice
      .PersistentSelectionRepresentation?
    /// visionOS: lets a fresh window re-resolve a sandboxed file URL.
    var securityScopedBookmark: Data?

    /// The entry the window is currently showing, or `nil` for a blank
    /// window or an out-of-range index (format drift degrades, not traps).
    var currentURL: URL {
      history.currentURL
    }

    var droppingHistory: Self {
      var result = self
      result.history = .init(url: currentURL)
      return result
    }

    init(url: URL) {
      self.init(history: History(url: url))
    }

    init(
      history: History,
      scroll: Scroll = .top,
      showsTOC: Bool = false,
      pageZoom: Double = 1.0,
      templatePersistent: SceneTemplateChoice
        .PersistentSelectionRepresentation? = nil,
      rendererPersistent: SceneProcessorChoice
        .PersistentSelectionRepresentation? = nil,
      colorSchemePersistent: SceneColorSchemeChoice
        .PersistentSelectionRepresentation? = nil,
      securityScopedBookmark: Data? = nil
    ) {
      self.history = history
      self.scroll = scroll
      self.showsTOC = showsTOC
      self.pageZoom = pageZoom
      self.templatePersistent = templatePersistent
      self.rendererPersistent = rendererPersistent
      self.colorSchemePersistent = colorSchemePersistent
      self.securityScopedBookmark = securityScopedBookmark
    }
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
      scroll: .location(currentScrollY),
      showsTOC: showsTOC,
      pageZoom: zoom.zoomScale,
      templatePersistent: templates.selectionRepresentation,
      rendererPersistent: processors.selectionRepresentation,
      colorSchemePersistent: colorSchemes.selectionRepresentation,
      securityScopedBookmark: nil)
  }
}

// MARK: - Per-scene instance cache + factories

extension CodingUserInfoKey {
  static let appModel = Self(rawValue: "appModel") !! "cannot happen"
}

extension DocumentModel: @MainActor Persistent {
  /// The singleton Help window's model — a bundled file, never
  /// persisted.
  static func help(appModel: AppModel, url: URL) -> DocumentModel {
    DocumentModel(appModel: appModel, url: url)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(snapshot)
  }

  /// Construct from a restored snapshot.
  convenience init(from decoder: Decoder) throws
  {
    let container = try decoder.singleValueContainer()
    let snapshot = try container.decode(Snapshot.self)
    guard let appModel = decoder.userInfo[.appModel] as? AppModel else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "missing appModel"))
    }
    self.init(appModel: appModel, snapshot: snapshot)
  }

  /// Construct from a restored snapshot.
  convenience init(appModel: AppModel, snapshot: Snapshot)
  {
    self.init(
      appModel: appModel,
      history: snapshot.history,
      templatePersistent: snapshot.templatePersistent,
      processorPersistent: snapshot.rendererPersistent,
      colorSchemePersistent: snapshot.colorSchemePersistent,
      initialScroll: snapshot.scroll,
      initialShowsTOC: snapshot.showsTOC,
      initialZoom: snapshot.pageZoom)
  }
}

// MARK: - Explicit model → store persistence (no view mediation)

extension DocumentModel {
  /// Arm the persistence observer. The model owns its own persistence —
  /// no view observes the model to write the store (see
  /// `feedback_no_view_mediated_model_mutation`). The tracked set is the
  /// durable fields; any change writes the snapshot to `DocumentStore`
  /// (both the window-keyed and file-keyed halves).
  func trackPersistentState() {
    _ = self.history
    _ = self.showsTOC
    _ = self.templates.selectionRepresentation
    _ = self.processors.selectionRepresentation
    _ = self.colorSchemes.selectionRepresentation
    _ = self.zoom.zoomScale
    _ = self.renderedTemplateID
  }

  /// Re-render when a render input changes: the global processor /
  /// template selection, the per-document-override toggle, or this
  /// window's own per-window choice overrides. Explicit model wiring —
  /// replaces the old `ChangeHandlers` `.onChange(of: appModel.…)` that
  /// had the view observe the app model to drive this model's reload.
  func startTrackingRenderInputs(appModel: AppModel) {
    reloadObservation = onObservedChange(
      track: { [weak self, weak appModel] in
        guard let self, let appModel else { return }
        _ = appModel.processors.selection
        _ = appModel.templates.selection
        _ = Defaults.shared.enablePerDocumentOverrides
        _ = self.templates.selection
        _ = self.processors.selection
        _ = self.colorSchemes.selection
      },
      onChange: { [weak self] in
        Task { await self?.reload() }
      })
  }
}
