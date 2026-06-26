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
  @ObservationIgnored private let httpTunnelResponder: Responder

  /// Server's loopback HTTP base URL, captured at `start(httpURL:)`
  /// time and read inside `makeLink()` to populate advertise-time
  /// metadata. `nil` if no HTTP listener is present / hadn't bound.
  @ObservationIgnored private var advertisedHTTPURL: URL?

  init(service: PreviewRequestService, watcher: DocumentWatcher) {
    self.httpTunnelResponder = Responder(
      backend: InProcessTunnelBackend(service: service, watcher: watcher))
  }

  /// Begin advertising. Idempotent. `httpURL` is the Server's loopback
  /// HTTP base URL once the listener has bound; it's published in the
  /// peer's Kosmos metadata so the Mac Viewer's pill can read the port
  /// for display without a side-channel file lookup. `nil` means the
  /// HTTP listener never came up — peers can still discover liveness
  /// but won't see a URL.
  func start(httpURL: URL?) {
    advertisedHTTPURL = httpURL
    host.start(service: self)
  }

  func stop() {
    httpTunnelResponder.stop()
    Task { await host.stop() }
  }

  // MARK: - KosmosService

  func makeLink() async -> KosmosClient {
    await host.makeLink(extraMetadata: [.httpURL => advertisedHTTPURL])
  }

  func configure(host: ServiceHost, client: KosmosClient) async {
    await registerHandlers(host: host)
    httpTunnelResponder.install(on: host, client: client)
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
    guard let destination = TunnelScheme.originURL.galleyPreviewURL(
      forFile: target.documentURL.safe.path)
    else {
      log.notice("""
        Failed \(target.documentURL.safe, privacy: .public)
        """)
      return false
    }
    let target = DocumentTarget(url: destination, scrollLine: target.scrollLine)
    let message = RouteToTunnelClient(target: target)
    host.publish(message) { peers.contains($0) }
    return true
  }

  @MainActor
  @discardableResult
  public static func dispatch(
    _ target: DocumentTarget,
    with kosmos: ServerKosmosService?) async -> Bool
  {
    if kosmos?.dispatchToClient(target, deviceType: .vision) == true {
      return true
    }
    log.notice("""
      dispatch → local Viewer (no AVP): \
      \(target, privacy: .public)
      """)
    if kosmos?.dispatchToClient(target, deviceType: .mac) == true {
      return true
    }
    log.notice("""
      dispatch → local Viewer (no tunnel): \
      \(target, privacy: .public)
      """)
    openInLocalViewer(target)
    return false
  }

  /// Surface a request in the Mac Viewer via its forced-local `dot://`
  /// URL — `.entry` navigates to the entry, `.search` opens search
  /// pre-populated. LaunchServices launches the Viewer if it isn't up.
  static func openInLocalViewer(_ request: DocumentTarget) {
    GalleyViewerRequestActivity(target: request).open()
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
  }
}
