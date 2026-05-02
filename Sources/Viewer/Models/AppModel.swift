import Foundation
import GalleyCoreKit
import SwiftUI

/// App-wide rendering preferences for the Viewer. Renderer selection
/// (catalog discovery + persisted ID), template store, server config,
/// and window-open behavior all live here, separately from any single
/// window's `DocumentModel`. Windows read the active renderer + template
/// at render time, so the user can switch globally and have every open
/// document re-render.
///
/// Backed by `@ObservableDefaults` on the shared `net.leuski.galley`
/// suite so port and processor/template choices are readable by the
/// Server process without any IPC.
@ObservableDefaults
final class Defaults: GalleyDefaults {
  @DefaultsKey var port: UInt16 = GalleyConstants.defaultPort
  @DefaultsKey var rendererPersistent: String?
  @DefaultsKey var templatePersistent: String?
  @DefaultsKey var enablePerDocumentOverrides: Bool = false
  @DefaultsKey var openBehavior: OpenBehavior = .newWindow
  @DefaultsKey var editorChoice: EditorChoice.Element = .preset(.bbedit)
  @DefaultsKey var perFileStateStore: [String: PerFileState] = [:]

  @MainActor static let shared = Defaults()
}

@MainActor @Observable
final class AppModel {
  // MARK: - In-memory state (not persisted by the macro)

  @ObservationIgnored let templateStore: TemplateStore
  let templates: TemplateChoice
  @ObservationIgnored let processorStore: ProcessorStore
  let processors: ProcessorChoice
  @ObservationIgnored let editors: EditorChoice

  /// Constructs an already-hydrated AppModel. Caller (`AppBoot`) is
  /// expected to have run async catalog discovery
  /// (`await processorStore.discover()`) before invoking this so
  /// `create(source:persistent:)` decodes the persisted pick against
  /// the live catalog and reports displacement honestly.
  init(templateStore: TemplateStore, processorStore: ProcessorStore) {
    self.templateStore = templateStore
    self.processorStore = processorStore
    self.editors = EditorChoice()

    self.templates = TemplateChoice(
      source: templateStore,
      persistent: Defaults.shared.templatePersistent) { name in
        Self.notify(.template, name)
      }

    self.processors = ProcessorChoice(
      source: processorStore,
      persistent: Defaults.shared.rendererPersistent) { name in
        Self.notify(.processor, name)
      }

    templateStore.onReload = { [weak self] in self?.afterTemplateReload() }

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
  func rediscoverRenderers() {
    Task {
      await processorStore.discover()
      if let name = processors.healIfDisplaced() {
        Self.notify(.processor, name)
      }
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
    DisplacementNotifier.post(kind: kind, displaced: name)
  }

  /// Mirror `selected` changes back to the shared defaults suite so
  /// the Server process picks them up at request time. The macro
  /// handles the actual UserDefaults write; this loop just keeps
  /// the `@DefaultsKey`-backed properties in sync with the choice envelopes.
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
        Defaults.shared.templatePersistent = self.templates.persistent
        Defaults.shared.rendererPersistent = self.processors.persistent
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
