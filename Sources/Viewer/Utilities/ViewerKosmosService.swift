import Foundation
import GalleyCoreKit
import KosmosCore
#if ENABLE_TUNNEL
import KosmosHTTPTunnel
#endif
import KosmosTransport
import Observation
import OSLog

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
final class ViewerKosmosService: ClientKosmosService {
  /// Viewer-side HTTP tunnel client. Exposed so `WebPage` configuration
  /// can hand it to the `KosmosTunnelSchemeHandler` it installs on
  /// the `galley://` scheme.
#if ENABLE_TUNNEL
  let tunnel: Client = Client(client: nil)
#endif

  @ObservationIgnored
  let host = ServiceHost(config: ViewerKosmosService.config(
    product: KosmosServiceHost.Config.product))

  init() {
  }

  // MARK: - KosmosService

  func makeLink() async -> KosmosClient {
    await makeLink(
      port: Defaults.shared.serverKosmosPort,
      deviceID: Defaults.shared.serverKosmosDeviceID)
  }

  func configure(host: ServiceHost, client: KosmosClient) async {
#if ENABLE_TUNNEL
    host.subscribe(RouteToClientMessage.self) { _, message in
      GalleyViewerRequestActivity(target: message.payload).open()
    }

    configureTunnel(client: client)
#endif
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

  // MARK: - Outbound

  /// Send `RouteToAVP` to this Mac's Server. Server decides where the
  /// file lands (AVP if reachable, else `NSWorkspace.open(galley://)`
  /// to the Mac Viewer's own LSHandler). The host logs the request,
  /// reply, and any transport error uniformly.
  @discardableResult
  func routeToAVP<M>(_ message: M) async throws -> M.Reply
  where M: KosmosMessageWithReply
  {
    guard host.client != nil
    else { throw ClientKosmosServiceRouteError.notReady }
    guard let serverPeer
    else { throw ClientKosmosServiceRouteError.noServer }
    return try await host.send(message, to: serverPeer)
  }

  @discardableResult
  func routeToAVP(_ target: DocumentTarget) async throws -> RouteToAVP.Reply {
    try await routeToAVP(RouteToAVP(target: target))
  }

#else
#endif
}
