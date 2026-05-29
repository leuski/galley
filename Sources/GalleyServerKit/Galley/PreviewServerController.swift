import Foundation
import Observation
import OSLog
import GalleyCoreKit
import KosmosAppKit

private let log = Logger(
  subsystem: bundleIdentifier, category: "PreviewServer")

/// Galley-specific facade over the generic `HTTPServerController`.
/// Owns the Galley wiring — the selected-template and renderer
/// provider closures, the shared `DocumentWatcher` that the SSE route
/// subscribes against — and delegates the lifecycle (state machine,
/// bound-URL publication, start/stop) to the generic controller.
///
/// The public surface is preserved from the pre-refactor type so that
/// `Sources/Server/App/AppModel.swift` and the existing
/// `PreviewServerControllerTests` see no change: same `State` cases,
/// same `state` / `serverURL` / `stateChanges` / `watcher` properties,
/// same `start()` / `stop()` methods. Inside, `start()` constructs the
/// router via `Routes.makeRouter(...)` and hands the lifecycle to
/// `HTTPServerController`.
///
/// Loopback-only by design. Same-machine consumers (Mac Viewer,
/// Quicklook, browsers, BBEdit) reach the listener via `127.0.0.1`.
/// AVP doesn't dial the HTTP listener directly — it tunnels each
/// request over Kosmos through `Responder`, which proxies to this
/// loopback endpoint on AVP's behalf. No HTTPS, no cert provisioning,
/// no AWDL ingress concerns.
@Observable
@MainActor
public final class PreviewServerController {
  /// Re-exported so call sites continue to write
  /// `PreviewServerController.State.running(...)` unchanged.
  public typealias State = HTTPServerState

  @ObservationIgnored
  private let http = HTTPServerController()

  @ObservationIgnored public let watcher = DocumentWatcher()

  @ObservationIgnored private let selectedTemplateProvider: @Sendable ()
    async -> Template
  @ObservationIgnored private let rendererProvider: @Sendable ()
    async -> (any MarkdownRenderer)?

  public init(
    selectedTemplateProvider: @escaping @Sendable () async -> Template,
    rendererProvider: @escaping @Sendable () async -> (any MarkdownRenderer)?
  ) {
    self.selectedTemplateProvider = selectedTemplateProvider
    self.rendererProvider = rendererProvider
  }

  /// State + URL forwarders. Reading these inside an observer scope
  /// registers a dependency on the inner controller's `state`, so
  /// SwiftUI views that observe the facade still see invalidations
  /// when the listener transitions.
  public var state: State { http.state }
  public var serverURL: URL? { http.serverURL }
  public var stateChanges: AsyncStream<State> { http.stateChanges }

  /// Starts the loopback HTTP listener. AVP traffic doesn't reach the
  /// listener directly — `Responder` proxies Kosmos
  /// `ProxyHTTPRequest` messages through the same endpoint.
  public func start() {
    let templateProvider = selectedTemplateProvider
    let renderProvider = rendererProvider
    let watcher = self.watcher

    http.start(bindHost: GalleyConstants.defaultHost) { boundURL in
      Routes.makeRouter(
        hostURLProvider: boundURL,
        extraAllowedHostsProvider: { [] },
        selectedTemplateProvider: templateProvider,
        rendererProvider: renderProvider,
        watcher: watcher)
    }
  }

  public func stop() {
    http.stop()
  }
}
