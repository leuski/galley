import Foundation
import SwiftUI
import Observation
import GalleyCoreKit
import GalleyServerKit

@Observable
@MainActor
final class AppModel {
  var port: UInt16 {
    get {
      access(keyPath: \.port)
      let stored = UserDefaults.standard.object(forKey: Keys.port) as? Int
      return stored.flatMap { UInt16(exactly: $0) } ?? Self.defaultPort
    }
    set {
      withMutation(keyPath: \.port) {
        UserDefaults.standard.set(Int(newValue), forKey: Keys.port)
      }
      restartServerIfRunning()
    }
  }

  var launchAtLogin: Bool {
    get {
      access(keyPath: \.launchAtLogin)
      return LoginItem.isEnabled
    }
    set {
      withMutation(keyPath: \.launchAtLogin) {
        _ = LoginItem.setEnabled(newValue)
      }
    }
  }

  @ObservationIgnored let templateStore: TemplateStore
  let templates: TemplateChoice
  @ObservationIgnored let processorStore: ProcessorStore
  let processors: ProcessorChoice
  @ObservationIgnored lazy var server: PreviewServerController = {
    PreviewServerController(
      templateStore: self.templateStore,
      selectedTemplateProvider: { [weak self] in
        await self?.templates.selected.value ?? .default
      },
      rendererProvider: { [weak self] in
        await self?.processors.selected.value.renderer
      })
  }()

  private enum Keys {
    static let port = "MarkdownPreviewer.port"
    static let rendererPersistent = "MarkdownPreviewer.rendererPersistent"
    static let templatePersistent = "MarkdownPreviewer.templatePersistent"
  }

  nonisolated static let defaultPort: UInt16 = 8089
  nonisolated static let defaultHost: String = "127.0.0.1"

  /// Constructs an already-hydrated AppModel. Caller (`AppBoot`) is
  /// expected to have run async catalog discovery
  /// (`await processorStore.discover()`) before invoking this so
  /// `create(source:persistent:)` decodes the persisted pick against
  /// the live catalog and reports displacement honestly.
  init(templateStore: TemplateStore, processorStore: ProcessorStore) {
    self.templateStore = templateStore
    self.processorStore = processorStore

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

    startServer()
    startPersistenceObservation()
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

  nonisolated private static func hostURL(port: UInt16? = nil) -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = Self.defaultHost
    components.port = Int(port ?? Self.defaultPort)
    guard let url = components.url else {
      preconditionFailure("hostURL components produced no URL")
    }
    return url
  }

  var hostURL: URL {
    Self.hostURL(port: self.port)
  }

  private func startServer() {
    server.start(url: hostURL)
  }

  private func restartServerIfRunning() {
    if case .running = server.state {
      startServer()
    }
  }
}

/// Boot wrapper that runs async processor discovery before
/// constructing the real AppModel. The view tree branches on
/// `model` being non-nil; while loading, a placeholder UI is shown.
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
