import Foundation
import GalleyCoreKit
import SwiftUI
import os

private let defaultsLog = Logger(
  subsystem: bundleIdentifier, category: "Defaults")

/// visionOS counterpart of the macOS Viewer's `AppModel`. Exposes
/// the minimum surface the shared `DocumentModel` reads:
///
/// - `templates: TemplateChoice`
/// - `processors: ProcessorChoice`
///
/// `editors` is intentionally absent — `DocumentModel.openInEditor`
/// is `#if os(macOS)`-gated. The external-editor concept (BBEdit /
/// VS Code / Xcode) does not apply on visionOS.
///
/// No `restartServerIfStale` either — visionOS does not host the
/// Galley Server, so there's no second process to keep in sync.
@MainActor @Observable
final class AppModel {
  let templates: TemplateChoice
  let processors: ProcessorChoice
  @ObservationIgnored private var persistenceTokens: [Cancelable] = []

  init() {
    Self.logInit(
      bundle: Bundle.main.bundleIdentifier,
      renderer: Defaults.shared.renderer,
      template: Defaults.shared.template)

    self.templates = TemplateChoice(
      source: TemplateStore.shared,
      persistent: Defaults.shared.template
    ) { name in
      DisplacementNotifier.post(kind: .template, displaced: name)
    }

    self.processors = ProcessorChoice(
      source: ProcessorStore.shared,
      persistent: Defaults.shared.renderer
    ) { name in
      DisplacementNotifier.post(kind: .processor, displaced: name)
    }

    // Round-trip the persistent IDs through `UserDefaults`. The macOS
    // Viewer additionally posts a `DefaultsBroadcast` so the Galley
    // Server picks the change up cross-process — irrelevant on
    // visionOS where no second process consumes the same suite.
    persistenceTokens = bindPersistent(
      templates,
      label: "VisionOSViewer.template",
      read: { Defaults.shared.template },
      write: { Defaults.shared.template = $0 })
    + bindPersistent(
      processors,
      label: "VisionOSViewer.processor",
      read: { Defaults.shared.renderer },
      write: { Defaults.shared.renderer = $0 })
  }

  private static func logInit(
    bundle: String?, renderer: String?, template: String?
  ) {
    let pid = ProcessInfo.processInfo.processIdentifier
    defaultsLog.notice("""
      visionOS AppModel init pid=\(pid) \
      bundle=\(bundle ?? "?", privacy: .public) \
      renderer=\(renderer ?? "nil", privacy: .public) \
      template=\(template ?? "nil", privacy: .public)
      """)
  }
}

/// Boot wrapper that runs async processor discovery before
/// constructing the real `AppModel`. The host view branches its
/// body on `boot.model` being non-nil.
///
/// On visionOS `ProcessorStore.discover()` returns the built-in
/// renderer only (external CLI processors are unreachable — the
/// kit guards `Process` use behind `#if os(macOS)`), so this is
/// effectively a one-shot await.
@Observable @MainActor
final class AppBoot {
  private(set) var model: AppModel?

  init() {
    Task { await DisplacementNotifier.requestAuthorization() }
    Task { @MainActor in
      await ProcessorStore.shared.discover()
      self.model = AppModel()
    }
  }
}
