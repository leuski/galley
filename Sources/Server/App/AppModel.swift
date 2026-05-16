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
final class Defaults: GalleyRenderDefaults {
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
    publishGalleyAppHash()
  }

  /// Compute the SHA256 of the Galley.app bundle that contains this
  /// Server.app and write it to the shared suite. The Viewer reads
  /// this on its launch and compares with its own hash; on mismatch
  /// it terminates and relaunches us so a stale Server doesn't
  /// clobber the Viewer's choices through the bindPersistent
  /// round-trip. (Server.app lives at
  /// `<Galley.app>/Contents/Resources/Galley Server.app`, so the
  /// containing app bundle is three levels up.)
  private func publishGalleyAppHash() {
    let serverBundle = Bundle.main.bundleURL
    let galleyApp = serverBundle
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    Task.detached(priority: .userInitiated) {
      do {
        let hash = try await GalleyAppHash.compute(at: galleyApp)
        await MainActor.run {
          SharedSuiteDefaults.suite.set(
            hash, forKey: SharedSuiteDefaults.serverGalleyHashKey)
          DefaultsBroadcast.post()
        }
      } catch {
        defaultsLog.error("""
          Server publishGalleyAppHash failed: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
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
    server.start()
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
