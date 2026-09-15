import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosHTTPTunnel
import KosmosTransport
import Observation
import OSLog

private let logger = Logger(category: "ServerKosmosService")

/// One per Server process. Owns the `KosmosServiceHost`, the
/// `PeerReachabilityTracker` that mirrors peer roles + AVP
/// reachability, and the per-window state for files currently
/// displayed on AVP. Built but not started by `AppModel.init`;
/// `AppModel.startServer()` calls `start()` after the preview server
/// is up so we have a port to publish on each `OpenDocument`.
///
/// When a `visionViewer` peer joins: AVP traffic rides the Kosmos
/// tunnel (`Responder`) — the Mac HTTP listener stays loopback-only.
///
/// When the last `visionViewer` peer leaves: walk the open-window set
/// and re-open each on the local Galley.app.
///
/// The `RouteToAVP` request from a Mac Viewer peer is dispatched
/// through the same path Finder-opens take (`dispatchOpenURLToAVP`),
/// so the AVP-vs-Mac decision stays in one place.
///
/// Boilerplate (bootstrap, peer-watch, subscription bookkeeping, stop)
/// lives in `KosmosServiceHost`; the peer-role mirror + suspend/resume
/// reachability gating + vision join/leave diffing live in the shared
/// `PeerReachabilityTracker`. What's left here is purely Galley's: what
/// gets dispatched to AVP (`OpenDocument` + `DocumentWatcher`) and how
/// a file falls back to the local app.
@MainActor
@Observable
final class ServerKosmosService: KosmosAppKit.ServerKosmosService
{
  @ObservationIgnored
  let host = ServiceHost(config: .server(
    product: KosmosServiceHost.Config.product))

  /// HTTP tunnel responder. Subscribes to `ProxyHTTPRequest` from AVP
  /// peers and renders each in-process via `InProcessTunnelBackend` —
  /// no loopback HTTP listener involved, so the tunnel works with or
  /// without the optional HTTP server.
  @ObservationIgnored
  let tunnel: Responder?

  init(service: PreviewRequestService, watcher: DocumentWatcher) {
    self.tunnel = Responder(
      backend: InProcessTunnelBackend(service: service, watcher: watcher))
  }

  /// Begin advertising. Idempotent.
  func start() {
    host.start(service: self)
  }

  func stop() {
    tunnel?.stop()
    clearKosmosEndpoint()
    Task { await host.stop() }
  }

  /// Once the link is up, publish the Kosmos `deviceID` + bound TCP port
  /// into the shared defaults so a same-Mac Viewer can eager-dial us as
  /// a seed peer instead of waiting on Bonjour browse+resolve. Cleared
  /// on `stop()`.
  func linkDidStart(_ error: (any Error)?) {
    guard error == nil else { return }
    Task { [weak self] in
      guard let self else { return }
      let port = await self.host.listeningPort() ?? 0
      self.publishKosmosEndpoint(port: port)
    }
  }

  private func publishKosmosEndpoint(port: UInt16) {
    Defaults.shared.serverKosmosDeviceID = host.deviceID
    Defaults.shared.serverKosmosPort = port
    Defaults.shared.post()
    logger.notice("""
      published Kosmos endpoint: \
      deviceID=\(self.host.deviceID, privacy: .public) \
      port=\(port, privacy: .public)
      """)
  }

  private func clearKosmosEndpoint() {
    Defaults.shared.serverKosmosPort = 0
    Defaults.shared.serverKosmosDeviceID = nil
    Defaults.shared.post()
  }

  func routeToTunnelClient(
    _ target: DocumentTarget) -> RouteToClientMessage
  {
    RouteToClientMessage(
      payload: target.tunneled(via: PeerID(host.deviceID)))
  }

  func openInLocalViewer(_ request: DocumentTarget) {
    GalleyViewerRequestActivity(target: request).open()
  }

  // MARK: - Subscription wiring

  func registerHandlers() async {
    // RouteToAVP: Mac Viewer asks "open this file wherever's best."
    // Reuses the same dispatch path Finder-opens use so the AVP-vs-Mac
    // decision stays in one place. The host logs the request and reply.
    await host.handle(RouteToAVP.self)
    { [weak self] _, request -> RouteToAVP.Reply in
      let dispatched = await (self?.dispatchToClient(
        request.target, deviceType: .vision) == true)
      return RouteToAVP.Reply(accepted: dispatched)
    }

    await host.handle(OpenInEditor.self)
    { @MainActor _, request -> OpenInEditor.Reply in
      guard let parsed = PreviewRoute(path: request.target.documentURL.path),
            case let .documentAsset(url) = parsed else {
        return OpenInEditor.Reply(accepted: false)
      }
      await Defaults.shared.resolvedEditor.openFileInEditor(
        url, line: request.target.scrollLine)
      return OpenInEditor.Reply(accepted: true)
    }
  }
}
