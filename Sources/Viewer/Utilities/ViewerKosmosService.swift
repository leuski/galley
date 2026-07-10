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
    let seeds: [LoomKosmosLink.Configuration.SeedPeer]
    if
      Defaults.shared.serverKosmosPort != 0,
      let deviceID = Defaults.shared.serverKosmosDeviceID
    {
      // Eager-dial this Mac's Server (if it has published its Kosmos
      // endpoint) so the Server session comes up without waiting on
      // Bonjour browse+resolve. Empty when nothing's published — the link
      // still advertises + browses, so discovery covers the Server (and
      // the AVP) either way.
      seeds = [.init(
        deviceID: deviceID,
        host: GalleyConstants.defaultHost,
        port: Defaults.shared.serverKosmosPort)]
    } else {
      seeds = []
    }
    return await host.makeLink(seedPeers: seeds)
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

  private func peer(for url: URL) throws -> PeerID {
    guard host.client != nil else { throw RouteError.notReady }
    guard let peerHost = url.host()?.lowercased(),
          !peerHost.isEmpty,
          let deviceID = DeviceID(peerHost)
    else { throw RouteError.noServer }
    let peer = PeerID(deviceID)
    guard host.peers[peer] != nil else { throw RouteError.noServer }
    return peer
  }

  /// Ask the Mac that hosts this document to open it in its editor.
  ///
  /// The document is a Mac-hosted tunnel URL
  /// (`kosmos://<server-id>/…`), and that host component *is* the
  /// serving Server's `PeerID` — the Server stamped its own Kosmos id
  /// there when it routed the document. So the request goes straight
  /// back to the exact Mac that owns the file, addressed by reading the
  /// URL host: no discovery, no side-table, no Mac host-UUID lookup, and
  /// correct with any number of Macs on the mesh. Only AVP shows tunnel
  /// documents, but the addressing is platform-independent.
  @discardableResult
  func openInEditor(
    _ target: DocumentTarget) async throws -> OpenInEditor.Reply
  {
    try await host
      .send(OpenInEditor(target: target), to: peer(for: target.documentURL))
  }

  enum RouteError: LocalizedError {
    /// `KosmosClient` not yet constructed — `start()` either hasn't
    /// been called, or its bootstrap is still pending.
    case notReady
    /// The document carried no serving-Server host, or no peer with
    /// that id is connected. Usually means Galley Server isn't running,
    /// or Local Network permission isn't granted.
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

#if os(macOS)
  /// This Mac's own Server, if connected. The `net.leuski.galley`
  /// defaults are machine-local, so the Server's published
  /// `serverKosmosDeviceID` unambiguously names *this* Mac's Server —
  /// we address it by that id directly. No LAN host-UUID
  /// disambiguation, and no dependence on `UUID.hostStable` (which can
  /// be nil, silently disabling the old `onHost:` filter so it would
  /// match a foreign Server). Drives the `routeToAVP` target for
  /// "Show on Vision Pro".
  var serverPeer: PeerID? {
    guard let deviceID = Defaults.shared.serverKosmosDeviceID
    else { return nil }
    let peer = PeerID(deviceID)
    return host.peers[peer] != nil ? peer : nil
  }

  /// Drives the "Show on Vision Pro" menu enabledness. Same resume-
  /// gated reachability the Server uses for dispatch, so the menu is
  /// enabled exactly when a route would actually land on AVP (rather
  /// than silently falling back to the Mac).
  var isAVPReachable: Bool {
    host.reachablePeer(deviceType: .vision) != nil
  }

  // MARK: - Outbound

  /// Send `RouteToAVP` to this Mac's Server. Server decides where the
  /// file lands (AVP if reachable, else `NSWorkspace.open(galley://)`
  /// to the Mac Viewer's own LSHandler). The host logs the request,
  /// reply, and any transport error uniformly.
  @discardableResult
  func routeToAVP(_ target: DocumentTarget) async throws -> RouteToAVP.Reply {
    guard host.client != nil else { throw RouteError.notReady }
    guard let serverPeer else { throw RouteError.noServer }
    return try await host.send(RouteToAVP(target: target), to: serverPeer)
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
