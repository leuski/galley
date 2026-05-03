import Foundation
import SwiftUI
import GalleyCoreKit
import GalleyServerKit

/// App-wide state for the Server. Port, processor, and template come
/// from the shared `net.leuski.galley` suite — the same plist the
/// Viewer writes — so Viewer Settings changes propagate here without
/// any IPC. `limitToInstance: false` tells ObservableDefaults to watch
/// for cross-process writes via `cfprefsd` and surface them as
/// Observable changes.
@ObservableDefaults(
  suiteName: "net.leuski.galley",
  limitToInstance: false)
final class Defaults: GalleyDefaults {
  @DefaultsKey var port: UInt16 = GalleyConstants.defaultPort
  @DefaultsKey var rendererPersistent: String?
  @DefaultsKey var templatePersistent: String?

  @MainActor static let shared = Defaults()
}

@MainActor @Observable
final class AppModel {

  // MARK: - In-memory state

  let templates: TemplateChoice
  let processors: ProcessorChoice
  @ObservationIgnored let server: PreviewServerController

  nonisolated static let defaultHost: String = "127.0.0.1"

  init() {
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

    self.server = PreviewServerController(
      selectedTemplateProvider: { [weak templates] in
        await templates?.selected.value ?? .default
      },
      rendererProvider: { [weak processors] in
        await processors?.selected.value.renderer
      })

    startServer()
    startPortObservation()
  }

  private static func notify(
    _ kind: DisplacementNotifier.Kind, _ name: String)
  {
    DisplacementNotifier.post(kind: kind, displaced: name)
  }

  private func startServer() {
    server.start(url: Defaults.shared.host)
  }

  private func restartServerIfRunning() {
    if case .running = server.state {
      startServer()
    }
  }

  /// Watches `self.port` via `withObservationTracking`. Cross-process
  /// writes from the Viewer surface as Observable changes here thanks
  /// to `limitToInstance: false` in `@ObservableDefaults`, so no
  /// manual KVO or notification observer is needed.
  private func startPortObservation() {
    Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await withCheckedContinuation
        { (cont: CheckedContinuation<Void, Never>) in
          withObservationTracking {
            _ = Defaults.shared.port
          } onChange: {
            cont.resume()
          }
        }
        self.restartServerIfRunning()
      }
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
      await ProcessorStore.shared.discover()
      self.model = AppModel()
    }
  }
}
