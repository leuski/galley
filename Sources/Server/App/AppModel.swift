import Foundation
import SwiftUI
import GalleyCoreKit
import GalleyServerKit
import os

private let defaultsLog = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

/// App-wide state for the Server. Port, processor, and template come
/// from the `net.leuski.galley` suite — the same plist the Viewer
/// writes via its standard domain — so picks made in either app
/// surface in the other. `limitToInstance: false` widens the local
/// observer to react to any UserDefaults change in this process;
/// cross-process change signaling is handled separately by
/// `DefaultsBroadcast` (Darwin notification) because
/// `UserDefaults.didChangeNotification` is process-local.
@ObservableDefaults(
  suiteName: "net.leuski.galley",
  limitToInstance: false)
final class Defaults: GalleyNetworkDefaults, GalleyRenderDefaults {
  @DefaultsKey var port: UInt16 = GalleyConstants.defaultPort
  @DefaultsKey var renderer: String?
  @DefaultsKey var template: String?

  @MainActor static let shared = Defaults()
}

@MainActor @Observable
final class AppModel {

  // MARK: - In-memory state

  let templates: TemplateChoice
  let processors: ProcessorChoice
  @ObservationIgnored let server: PreviewServerController
  @ObservationIgnored private var persistenceTokens: [Cancelable] = []

  nonisolated static let defaultHost: String = "127.0.0.1"

  init() {
    Self.logInit(
      bundle: Bundle.main.bundleIdentifier,
      renderer: Defaults.shared.renderer,
      template: Defaults.shared.template)
    self.templates = TemplateChoice(
      source: TemplateStore.shared,
      persistent: Defaults.shared.template) { name in
        Self.notify(.template, name)
      }

    self.processors = ProcessorChoice(
      source: ProcessorStore.shared,
      persistent: Defaults.shared.renderer) { name in
        Self.notify(.processor, name)
      }

    self.server = PreviewServerController(
      selectedTemplateProvider: { [weak templates] in
        await templates?.selected.value ?? .default
      },
      rendererProvider: { [weak processors] in
        await processors?.selected.value.renderer
      })

    // Bidirectional sync with the shared `net.leuski.galley.shared`
    // suite. Outbound: menu-bar picks here surface in the Viewer
    // process. Inbound: Viewer Settings picks here update the
    // Server's request-time renderer/template providers.
    // See the same block in `Sources/Viewer/Models/AppModel.swift`
    // for the rationale: `UserDefaults.didChangeNotification` is
    // process-local; the Darwin-notification bridge is what makes
    // cross-process change observation actually work.
    DefaultsBroadcast.startListening()

    persistenceTokens = bindPersistent(
      templates,
      label: "Server.template",
      read: { Defaults.shared.template },
      write: {
        Defaults.shared.template = $0
        DefaultsBroadcast.post()
      })
    + bindPersistent(
      processors,
      label: "Server.processor",
      read: { Defaults.shared.renderer },
      write: {
        Defaults.shared.renderer = $0
        DefaultsBroadcast.post()
      })

    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        Self.logDidChange(
          renderer: Defaults.shared.renderer,
          template: Defaults.shared.template)
      }
    }

    startServer()
    startPortObservation()
  }

  private static func notify(
    _ kind: DisplacementNotifier.Kind, _ name: String)
  {
    DisplacementNotifier.post(kind: kind, displaced: name)
  }

  private static func logInit(
    bundle: String?, renderer: String?, template: String?
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    defaultsLog.notice("""
      Server AppModel init pid=\(pid) \
      bundle=\(bundle ?? "?", privacy: .public) \
      renderer=\(renderer ?? "nil", privacy: .public) \
      template=\(template ?? "nil", privacy: .public)
      """)
  }

  private static func logDidChange(
    renderer: String?, template: String?
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    defaultsLog.debug("""
      Server didChange pid=\(pid) \
      renderer=\(renderer ?? "nil", privacy: .public) \
      template=\(template ?? "nil", privacy: .public)
      """)
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
