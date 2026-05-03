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
/// Server process without any IPC. `limitToInstance: false` lets
/// cross-process writes from the Server (cfprefsd-broadcast) surface
/// here as Observable changes, which is what `bindPersistent` rides
/// to keep the model in sync.
@ObservableDefaults(limitToInstance: false)
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

  let templates: TemplateChoice
  let processors: ProcessorChoice
  @ObservationIgnored let editors: EditorChoice
  @ObservationIgnored private var persistenceTokens: [Cancelable] = []

  /// Constructs an already-hydrated AppModel. Caller (`AppBoot`) is
  /// expected to have run async catalog discovery
  /// (`await processorStore.discover()`) before invoking this so the
  /// initial decode lands honestly. Once constructed, processor and
  /// template selections stay in sync with the shared defaults suite
  /// in both directions — Server writes propagate here automatically
  /// via `limitToInstance: false`.
  init() {
    self.editors = EditorChoice()

    self.templates = TemplateChoice(
      source: TemplateStore.shared,
      persistent: Defaults.shared.templatePersistent) { name in
        Self.notify(.template, name)
      }

    self.processors = ProcessorChoice(
      source: ProcessorStore.shared,
      persistent: Defaults.shared.rendererPersistent) { name in
        Self.notify(.processor, name)
      }

    persistenceTokens = bindPersistent(
      templates,
      read: { Defaults.shared.templatePersistent },
      write: { Defaults.shared.templatePersistent = $0 })
    + bindPersistent(
      processors,
      read: { Defaults.shared.rendererPersistent },
      write: { Defaults.shared.rendererPersistent = $0 })
  }

  private static func notify(
    _ kind: DisplacementNotifier.Kind, _ name: String)
  {
    DisplacementNotifier.post(kind: kind, displaced: name)
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
      await ProcessorStore.shared.discover()
      self.model = AppModel()
    }
  }
}

// `OpenBehavior` lives in GalleyCoreKit/Routing/ now so the routing
// layer is platform-agnostic and unit-testable. Re-exported via the
// `import GalleyCoreKit` above.
