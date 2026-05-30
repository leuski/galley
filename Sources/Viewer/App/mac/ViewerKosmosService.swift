#if os(macOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosTransport
import Observation

// All message I/O and peer/link diagnostics for this surface are logged
// uniformly by `KosmosServiceHost`; this file has no logger of its own.

/// Mac Viewer's Kosmos surface. Narrow by design: peer presence for
/// two UI gates (Server pill, "Show on Vision Pro" enabledness) and
/// a single outbound `RouteToAVP` request. The Mac Viewer does not
/// own dispatch state — Server is the routing authority.
///
/// Conforms to `KosmosService`; the `KosmosServiceHost` owns the
/// bootstrap / peer-watch / stop boilerplate and calls back through
/// the protocol.
///
/// Peer presence is resolved by the host's product-scoped queries:
/// `presentPeer(role:onHost:)` for *this* Mac's Server, and
/// `reachablePeer(deviceType:.vision)` for the AVP. The AVP query is
/// resume-gated — identical to the policy the Server uses for dispatch
/// — so "Show on Vision Pro" is enabled exactly when a route would
/// actually land on AVP. (The AVP only emits `AppWillSuspend` on real
/// suspension, reading aggregate App-level `scenePhase`, so gating here
/// no longer risks the focus-blip flicker that an earlier membership-
/// only workaround was guarding against.)
@MainActor
@Observable
final class ViewerKosmosService: KosmosService<GalleyKosmosRole> {
  /// `kosmos.host` of this Mac, used to recognise the local Server
  /// out of any other Servers reachable on the network.
  @ObservationIgnored private let localHostUUID = UUID.hostStable?
    .uuidString.lowercased()

  @ObservationIgnored private let host = ServiceHost(role: .macViewer)

  /// Begin advertising. Idempotent.
  func start() {
    host.start(service: self)
  }

  func stop() async {
    await host.stop()
  }

  // MARK: - KosmosService

  func makeLink() async -> KosmosClient {
    await host.makeLink()
  }

  // Peer-snapshot and link-start/fail logging are handled uniformly by
  // `KosmosServiceHost`; this surface overrides neither `peersChanged`
  // nor `linkDidStart`.

  // MARK: - Derived state

  /// This Mac's local Server, if present. `onHost:` restricts the
  /// match to a Server on *this* Mac (others on the LAN are visible but
  /// ignored), and `presentPeer(role:)` is product-scoped, so a Dot
  /// Server on the same machine never matches.
  var serverPeer: PeerID? {
    host.presentPeer(role: .server, onHost: localHostUUID)
  }

  /// Drives the Server-status pill.
  var isServerPeerConnected: Bool { serverPeer != nil }

  /// HTTP base URL the Server published in its peer metadata at
  /// advertise time. `nil` until the Server peer appears with a URL
  /// in metadata. Drives the port number shown in `.running` pill text.
  var serverPeerHTTPURL: URL? {
    guard let id = serverPeer, let info = host.peers[id] else { return nil }
    return info.metadata[.httpURL]
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
        Galley Server isn’t reachable. Make sure it’s running and \
        that Local Network access is granted to Galley in System \
        Settings → Privacy & Security.
        """
      }
    }
  }
}
#endif
