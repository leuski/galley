import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosHTTPTunnel
import KosmosTransport
import Observation
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "ServerKosmosService")

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
final class ServerKosmosService: KosmosService<GalleyKosmosRole> {
  /// AVP currently reachable: a same-product `vision` peer is connected
  /// AND its last lifecycle message was a resume. Resolved by the host.
  var isAVPReachable: Bool { host.reachablePeer(deviceType: .vision) != nil }

  @ObservationIgnored private let host = ServiceHost(role: .server)

  /// HTTP tunnel responder. Subscribes to `ProxyHTTPRequest` from AVP
  /// peers and renders each in-process via `InProcessTunnelBackend` —
  /// no loopback HTTP listener involved, so the tunnel works with or
  /// without the optional HTTP server.
  @ObservationIgnored private let tunnelResponder: Responder

  init(service: PreviewRequestService, watcher: DocumentWatcher) {
    self.tunnelResponder = Responder(
      backend: InProcessTunnelBackend(service: service, watcher: watcher))
  }

  /// Begin advertising. Idempotent.
  func start() {
    host.start(service: self)
  }

  func stop() {
    tunnelResponder.stop()
    clearKosmosEndpoint()
    Task { await host.stop() }
  }

  // MARK: - KosmosService

  func makeLink() async -> KosmosClient {
    await host.makeLink()
  }

  func configure(host: ServiceHost, client: KosmosClient) async {
    await registerHandlers(host: host)
    tunnelResponder.install(on: host, client: client)
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
    log.notice("""
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

  func peersChanged(_ snapshot: [PeerID: PeerInfo]) {
    // The host logs the snapshot and mirrors reachability; the Server's
    // only reaction is to migrate any windows back to the Mac when the
    // AVP they were delegated to drops out of the peer set.
  }

  private func reachablePeers() -> String {
    host.peers.values
      .map { $0.role ?? "?" }
      .sorted()
      .joined(separator: ", ")
  }

  /// Send a routing target to the reachable AVP peer. Returns false when
  /// no AVP peer is reachable (caller falls back to the local Viewer).
  @discardableResult
  func dispatchToClient(
    _ target: DocumentTarget, deviceType: DeviceType) -> Bool
  {
    let peers = host.reachablePeers(deviceType: deviceType).asSet()
    guard !peers.isEmpty else {
      log.notice("""
        dispatch: no reachable AVP peer — \
        \(self.host.peers.count, privacy: .public) peer(s): \
        [\(self.reachablePeers(), privacy: .public)]
        """)
      return false
    }
    // Stamp our own Kosmos id as the tunnel URL's host, so the AVP can
    // address follow-up requests (open-in-editor) back to *this* Mac by
    // reading `documentURL.host` — no side-table, no host-UUID lookup.
    let destination = TunnelScheme
      .originURL(forPeer: PeerID(host.deviceID))
      .appending(.documentAsset(target.documentURL))
    let target = DocumentTarget(url: destination, scrollLine: target.scrollLine)
    let message = RouteToTunnelClient(target: target)
    host.publish(message) { peers.contains($0) }
    return true
  }

  @discardableResult
  private func dispatch(_ target: DocumentTarget) async -> Bool
  {
    guard !dispatchToClient(target, deviceType: .vision) else {
      return true
    }
    log.notice("""
      dispatch → local Viewer (no AVP): \
      \(target, privacy: .public)
      """)
    guard !dispatchToClient(target, deviceType: .mac) else {
      return true
    }
    log.notice("""
      dispatch → local Viewer (no tunnel): \
      \(target, privacy: .public)
      """)
    GalleyViewerRequestActivity(target: target).open()
    return false
  }

  public func dispatch(_ targets: [DocumentTarget]) {
    Task {
      for target in targets {
        await self.dispatch(target)
      }
    }
  }

  // MARK: - Subscription wiring

  private func registerHandlers(host: ServiceHost) async {
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
