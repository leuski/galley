import Foundation
import GalleyCoreKit
import Observation
import SwiftUI

/// App-wide rendering preferences for the Viewer. Renderer selection
/// (catalog discovery + persisted ID) and the user's template store
/// both live here, separately from any single window's `DocumentModel`.
/// Windows read the active renderer + template at render time, so the
/// user can switch globally and have every open document re-render.
@Observable
@MainActor
final class AppModel {
  @ObservationIgnored let templateStore: TemplateStore
  let templates: TemplateChoice
  @ObservationIgnored let processorStore: ProcessorStore
  let processors: ProcessorChoice
  @ObservationIgnored let editors: EditorChoice
  @ObservationIgnored let perFileState: PerFileStateStore

  /// When on, each window can pin its own renderer / template that
  /// wins over the global selection. Stored per-window via
  /// `@SceneStorage`; toggling this off doesn't erase the per-window
  /// values, but stops them from taking effect.
  var enablePerDocumentOverrides: Bool {
    didSet {
      UserDefaults.standard.set(
        enablePerDocumentOverrides, forKey: Keys.perDocOverrides)
    }
  }

  /// How the app should handle a new document open request from
  /// Finder, the open panel, or Open Recent. Defaults to opening a
  /// fresh window (the historical behavior).
  var openBehavior: OpenBehavior {
    didSet {
      UserDefaults.standard.set(
        openBehavior.rawValue, forKey: Keys.openBehavior)
    }
  }

  private enum Keys {
    static let rendererPersistent = "\(keyPrefix).rendererPersistent"
    static let perDocOverrides = "\(keyPrefix).perDocumentOverrides"
    static let openBehavior = "\(keyPrefix).openBehavior"
    static let templatePersistent = "\(keyPrefix).templatePersistent"
  }

  /// Constructs an already-hydrated AppModel. Caller (`AppBoot`) is
  /// expected to have run async catalog discovery
  /// (`await processorStore.discover()`) before invoking this so
  /// `create(source:persistent:)` decodes the persisted pick against
  /// the live catalog and reports displacement honestly.
  init(templateStore: TemplateStore, processorStore: ProcessorStore) {
    self.templateStore = templateStore
    self.processorStore = processorStore
    self.editors = EditorChoice()
    self.perFileState = PerFileStateStore()
    self.enablePerDocumentOverrides = UserDefaults.standard.bool(
      forKey: Keys.perDocOverrides)
    self.openBehavior = OpenBehavior(
      rawValue: UserDefaults.standard.string(forKey: Keys.openBehavior)
        ?? "")
      ?? .newWindow

    let (templates, displacedTemplate) = TemplateChoice.create(
      source: templateStore,
      persistent: UserDefaults.standard.string(
        forKey: Keys.templatePersistent))
    self.templates = templates

    let (processors, displacedProcessor) = ProcessorChoice.create(
      source: processorStore,
      persistent: UserDefaults.standard.string(
        forKey: Keys.rendererPersistent))
    self.processors = processors

    templateStore.onReload = { [weak self] in self?.afterTemplateReload() }

    if let name = displacedTemplate { Self.notify(.template, name) }
    if let name = displacedProcessor { Self.notify(.processor, name) }

    startPersistenceObservation()
  }

  func template(forID id: String) -> Template? {
    templateStore.existingTemplate(forID: id)
  }

  /// Renderer to use for the current preview. Wraps swift-markdown
  /// with `annotatesSourceLines: true` so cmd-click → BBEdit works.
  var activeRenderer: any MarkdownRenderer {
    processors.selected.value.renderer ?? SwiftMarkdownRenderer()
  }

  var activeTemplate: Template {
    templates.selected.value
  }

  func selectTemplate(_ template: Template) {
    templates.selected = TemplateChoice.Element(template)
  }

  /// Re-runs discovery and heals the persisted pick against the
  /// fresh catalog. Posts a notification if the pick was displaced.
  func rediscoverRenderers() async {
    await processorStore.discover()
    if let name = processors.healIfDisplaced() {
      Self.notify(.processor, name)
    }
  }

  private func afterTemplateReload() {
    if let name = templates.healIfDisplaced() {
      Self.notify(.template, name)
    }
  }

  private static func notify(
    _ kind: DisplacementNotifier.Kind, _ name: String)
  {
    Task { await DisplacementNotifier.post(kind: kind, displaced: name) }
  }

  /// Mirror `selected` changes back to UserDefaults. One observation
  /// loop tracks both choices; each iteration rewrites both keys
  /// (cheap — they're tiny strings) and re-arms.
  private func startPersistenceObservation() {
    Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await withCheckedContinuation
        { (cont: CheckedContinuation<Void, Never>) in
          withObservationTracking {
            _ = self.templates.selected
            _ = self.processors.selected
          } onChange: {
            cont.resume()
          }
        }
        UserDefaults.standard.set(
          self.templates.persistent, forKey: Keys.templatePersistent)
        UserDefaults.standard.set(
          self.processors.persistent, forKey: Keys.rendererPersistent)
      }
    }
  }

  func revealTemplatesFolder() {
    templateStore.revealFolder()
  }
}

/// Boot wrapper that runs async processor discovery before
/// constructing the real AppModel. ContentView always mounts as
/// the WindowGroup's content (so `@SceneStorage` and URL
/// restoration work as usual) and branches its body on
/// `boot.model` being non-nil.
@Observable @MainActor
final class AppBoot {
  private(set) var model: AppModel?

  init() {
    // Notification permission is presented as a system sheet on
    // first run; awaiting it would block boot until the user
    // responds. Fire it in parallel and let it resolve whenever.
    Task { await DisplacementNotifier.requestAuthorization() }
    Task { @MainActor in
      let templateStore = TemplateStore()
      let processorStore = ProcessorStore()
      await processorStore.discover()
      self.model = AppModel(
        templateStore: templateStore,
        processorStore: processorStore)
    }
  }
}

/// Strategy for handling an "open this file" request from Finder, the
/// open panel, or Open Recent when at least one Viewer window is
/// already up. With no existing windows, every behavior collapses to
/// "open a new window."
enum OpenBehavior: String, CaseIterable, Identifiable, Sendable {
  /// Always spawn a fresh window.
  case newWindow
  /// Spawn a fresh window and merge it as a tab into the frontmost
  /// existing window (so the user ends up with a tab strip).
  case newTab
  /// Reuse the frontmost window — rebind it to the new document
  /// instead of creating another window.
  case replaceCurrent

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .newWindow: return "New Window"
    case .newTab: return "New Tab in Frontmost Window"
    case .replaceCurrent: return "Replace Frontmost Document"
    }
  }
}
