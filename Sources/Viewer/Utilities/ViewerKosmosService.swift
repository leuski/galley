import Foundation
import GalleyCoreKit
import KosmosCore
#if ENABLE_TUNNEL
import KosmosHTTPTunnel
#endif
import KosmosTransport
import Observation
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "ViewerKosmosService")

/// Viewer-side Kosmos surface. Advertises as a `visionViewer`, mirrors
/// the discovered peer set, subscribes to bridge messages (open-document,
/// content changes), and publishes lifecycle to the bridge so the Mac
/// can gate Viewer reachability on suspend / resume.
///
/// Also owns the Viewer end of the HTTP tunnel — every `galley://` URL
/// the WebView fetches becomes a `ProxyHTTPRequest` Kosmos broadcast,
/// and the response chunks are routed back through
/// `Client`. The service is the single subscription point
/// for the two response message types so we don't spin up a per-request
/// subscription.
///
/// Conforms to `KosmosService`; the `KosmosServiceHost` owns the
/// bootstrap / peer-watch / stop boilerplate and calls back through
/// the protocol.
@MainActor
@Observable
final class ViewerKosmosService: KosmosService<GalleyKosmosRole> {
  /// Viewer-side HTTP tunnel client. Exposed so `WebPage` configuration
  /// can hand it to the `KosmosTunnelSchemeHandler` it installs on
  /// the `galley://` scheme.
#if ENABLE_TUNNEL
  let tunnel: Client
#endif

  /// `kosmos.host` of this Mac, used to recognise the local Server
  /// out of any other Servers reachable on the network.
  @ObservationIgnored private let localHostUUID = UUID.hostStable?
    .uuidString.lowercased()

#if os(macOS)
  @ObservationIgnored private let host = ServiceHost(role: .macViewer)
#else
  @ObservationIgnored private let host = ServiceHost(role: .visionViewer)
#endif

  init() {
#if ENABLE_TUNNEL
    self.tunnel = Client(client: nil)
#endif
  }

  /// Begin advertising and browsing. Idempotent.
  func start() {
    host.start(service: self)
  }

  func stop() async {
#if ENABLE_TUNNEL
    tunnel.stopAll()
#endif
    await host.stop()
  }

  // MARK: - KosmosService

  func makeLink() async -> KosmosClient {
    await host.makeLink()
  }

  func configure(host: ServiceHost, client: KosmosClient) async {
#if ENABLE_TUNNEL
    host.subscribe(RouteToTunnelClient.self) { _, message in
      GalleyViewerRequestActivity(target: message.target).open()
    }

    // Receiver-side tunnel wiring (response frames → the in-flight
    // request) is shared in `KosmosHTTPTunnel`; the wire framing is its
    // concern, not ours.
    tunnel.install(on: host, pendingClient: client)
    tunnel.attachTunnelIf(serverPresent: host.presentPeer(role: .server) != nil)
#endif
  }

  func peersChanged(_ snapshot: [PeerID: PeerInfo]) {
#if ENABLE_TUNNEL
    tunnel.attachTunnelIf(serverPresent: host.presentPeer(role: .server) != nil)
#endif
  }
}

extension ViewerKosmosService {
#if os(macOS)
  /// This Mac's local Server, if present. `onHost:` restricts the
  /// match to a Server on *this* Mac (others on the LAN are visible but
  /// ignored), and `presentPeer(role:)` is product-scoped, so a Dot
  /// Server on the same machine never matches.
  var serverPeer: PeerID? {
    host.presentPeer(role: .server, onHost: localHostUUID)
  }

  /// Drives the "Show on Vision Pro" menu enabledness. Same resume-
  /// gated reachability the Server uses for dispatch, so the menu is
  /// enabled exactly when a route would actually land on AVP (rather
  /// than silently falling back to the Mac).
  var isAVPReachable: Bool {
    host.reachablePeer(deviceType: .vision) != nil
  }

  // MARK: - Outbound

  /// Send `RouteToAVP` to the local Server. Server decides where the
  /// file lands (AVP if reachable, else `NSWorkspace.open(galley://)`
  /// to the Mac Viewer's own LSHandler).
  /// Send `RouteToAVP` to this Mac's Server. The host logs the request,
  /// reply, and any transport error uniformly.
  @discardableResult
  func routeToAVP(_ target: DocumentTarget) async throws -> RouteToAVP.Reply {
    guard host.client != nil else { throw RouteError.notReady }
    guard let serverPeer else { throw RouteError.noServer }
    return try await host.send(RouteToAVP(target: target), to: serverPeer)
  }

  @discardableResult
  func openInEditor(
    _ target: DocumentTarget) async throws -> OpenInEditor.Reply
  {
    guard host.client != nil else { throw RouteError.notReady }
    guard let serverPeer else { throw RouteError.noServer }
    return try await host.send(OpenInEditor(target: target), to: serverPeer)
  }

  enum RouteError: LocalizedError {
    /// `KosmosClient` not yet constructed — `start()` either hasn't
    /// been called, or its bootstrap is still pending.
    case notReady
    /// No peer with `role=.server` matching this Mac's host UUID is
    /// in `client.peers`. Usually means Galley Server isn't running,
    /// or Local Network permission isn't granted to this app.
    case noServer

    var errorDescription: String? {
      switch self {
      case .notReady:
        "Kosmos link isn’t ready yet. Try again in a moment."
      case .noServer:
        """
        Galley Helper isn’t reachable. Make sure it’s running and \
        that Local Network access is granted to Galley in System \
        Settings → Privacy & Security.
        """
      }
    }
  }
#else

  /// Notify peers that AVP is about to suspend (`scenePhase`
  /// transitioned to `.background` — every scene gone, i.e. real
  /// suspension). The Server folds this into its per-peer resumed flag
  /// and falls back to the local Mac for subsequent opens until
  /// `publishResume` fires. Emission is a generic host capability — any
  /// surface can announce its lifecycle; AVP is just the one that does.
  func publishSuspend() {
    host.publishSuspend()
  }

  /// Notify peers that AVP is serviceable again.
  func publishResume() {
    host.publishResume()
  }

#endif
}
