import Foundation
import GalleyCoreKit
import SwiftUI
import os

private let defaultsLog = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

/// App-wide rendering preferences for the Viewer. Renderer selection
/// (catalog discovery + persisted ID), template store, server config,
/// and window-open behavior all live here, separately from any single
/// window's `DocumentModel`. Windows read the active renderer + template
/// at render time, so the user can switch globally and have every open
/// document re-render.
///
/// Backed by `@ObservableDefaults` on `UserDefaults.standard` — for
/// the Viewer that's `~/Library/Preferences/net.leuski.galley.plist`,
/// the same plist the Server reaches via
/// `UserDefaults(suiteName: "net.leuski.galley")`. (The Viewer cannot
/// itself open a suite with that name: `UserDefaults(suiteName:)`
/// returns nil when the suite equals the calling app's own bundle
/// id.) `limitToInstance: false` widens the local observer to react
/// to any UserDefaults change in this process; cross-process change
/// signaling is handled separately by `DefaultsBroadcast` (Darwin
/// notification) because `UserDefaults.didChangeNotification` is
/// process-local.
@ObservableDefaults(limitToInstance: false)
final class Defaults: GalleyNetworkDefaults, GalleyRenderDefaults {
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
    let pid = ProcessInfo.processInfo.processIdentifier
    let bid = Bundle.main.bundleIdentifier ?? "?"
    let renderer = Defaults.shared.rendererPersistent ?? "nil"
    let template = Defaults.shared.templatePersistent ?? "nil"
    defaultsLog.notice(
      """
      Viewer AppModel init pid=\(pid) bundle=\(bid, privacy: .public) \
      renderer=\(renderer, privacy: .public) \
      template=\(template, privacy: .public)
      """)
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

    // Darwin-notification bridge: `UserDefaults.didChangeNotification`
    // is process-local, so the Server (a near-idle menu-bar app) never
    // wakes up to re-read the shared suite when the Viewer writes.
    // `startListening` translates inbound Darwin notifications into a
    // local didChangeNotification post that the ObservableDefaults
    // macro observer is already subscribed to. `post()` after each
    // outbound write fires the cross-process signal.
    DefaultsBroadcast.startListening()

    persistenceTokens = bindPersistent(
      templates,
      label: "Viewer.template",
      read: { Defaults.shared.templatePersistent },
      write: {
        Defaults.shared.templatePersistent = $0
        DefaultsBroadcast.post()
      })
    + bindPersistent(
      processors,
      label: "Viewer.processor",
      read: { Defaults.shared.rendererPersistent },
      write: {
        Defaults.shared.rendererPersistent = $0
        DefaultsBroadcast.post()
      })

    // Log every ObservableDefaults notification arriving in this
    // process — that's the signal bindPersistent's inbound side
    // listens to. If this fires but the choice doesn't update,
    // the gap is in bindPersistent or downstream observation.
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        let renderer = Defaults.shared.rendererPersistent ?? "nil"
        let template = Defaults.shared.templatePersistent ?? "nil"
        defaultsLog.debug(
          """
          Viewer didChange pid=\(pid) \
          renderer=\(renderer, privacy: .public) \
          template=\(template, privacy: .public)
          """)
      }
    }
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
