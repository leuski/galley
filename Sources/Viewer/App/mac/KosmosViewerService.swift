#if os(macOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosTransport
import Observation
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "KosmosViewerService")

/// Mac Viewer's Kosmos surface. Narrow by design: peer presence for
/// two UI gates (Server pill, "Show on Vision Pro" enabledness) and
/// a single outbound `RouteToAVP` request. The Mac Viewer does not
/// own dispatch state — Server is the routing authority.
///
/// Conforms to `KosmosService`; the `KosmosServiceHost` owns the
/// bootstrap / peer-watch / stop boilerplate and calls back through
/// the protocol.
@MainActor
@Observable
final class KosmosViewerService: KosmosService {
  /// `kosmos.host` of this Mac, used to recognise the local Server
  /// out of any other Servers reachable on the network.
  @ObservationIgnored private let localHostUUID = UUID.hostStable?
    .uuidString.lowercased()

  @ObservationIgnored private let host = KosmosServiceHost(role: .macViewer)

  /// Begin advertising. Idempotent.
  func start() {
    host.start(service: self)
  }

  func stop() async {
    await host.stop()
  }

  // MARK: - KosmosService

  func makeLink() async -> KosmosClient {
    await host.makeLink(role: .macViewer)
  }

  func peersChanged(_ snapshot: [PeerID: PeerInfo]) {
    let summary = snapshot.values
      .map { info in
        let role = info.galleyRole?.rawValue ?? "nil"
        let url = info.galleyHTTPURL?.absoluteString ?? "-"
        return "\(info.id.description)[role=\(role) url=\(url)]"
      }
      .sorted()
      .joined(separator: ", ")
    log.notice("""
      peer-snapshot count=\(snapshot.count, privacy: .public) \
      peers=[\(summary, privacy: .public)]
      """)
  }

  func linkDidStart(_ error: (any Error)?) {
    if let error {
      log.error("""
        Kosmos link failed to start: \
        \(error.localizedDescription, privacy: .public). \
        Check Console.app for subsystem net.leuski.galley, and \
        verify Local Network permission for Galley in System Settings.
        """)
      return
    }
    guard let client = host.client else { return }
    Task {
      let identity = await client.identity.description
      log.notice("""
        Kosmos link started identity=\(identity, privacy: .public)
        """)
    }
  }

  // MARK: - Derived state

  /// First reachable Server whose `kosmos.host` matches this Mac's.
  /// Peers with the same role on other Macs are visible in
  /// `client.peers` but ignored here so the pill / menu don't track
  /// strangers.
  var serverPeer: PeerID? {
    GalleyPeerClassifier.serverPeer(
      in: host.peers, localHostUUID: localHostUUID)
  }

  /// First reachable AVP. Reachability is purely peer-set membership
  /// — if AVP's Kosmos session is up, AVP can receive. Earlier code
  /// gated on `AppWillSuspend` / `AppDidResume` lifecycle messages,
  /// but visionOS scene phase fires `.background` for focus blips
  /// that aren't real suspension and would disable the menu while a
  /// viewer window was visibly open.
  var avpPeer: PeerID? {
    GalleyPeerClassifier.avpPeer(in: host.peers)
  }

  /// Drives the Server-status pill.
  var isServerPeerConnected: Bool { serverPeer != nil }

  /// HTTP base URL the Server published in its peer metadata at
  /// advertise time. `nil` until the Server peer appears with a URL
  /// in metadata. Drives the port number shown in `.running` pill text.
  var serverPeerHTTPURL: URL? {
    guard let id = serverPeer, let info = host.peers[id] else { return nil }
    return info.galleyHTTPURL
  }

  /// Drives the "Show on Vision Pro" menu enabledness.
  var isAVPReachable: Bool { avpPeer != nil }

  // MARK: - Outbound

  /// Send `RouteToAVP` to the local Server. Server decides where the
  /// file lands (AVP if reachable, else `NSWorkspace.open(galley://)`
  /// to the Mac Viewer's own LSHandler).
  @discardableResult
  func routeToAVP(_ target: DocumentTarget) async throws -> RouteToAVP.Reply {
    guard let client = host.client else {
      throw RouteError.notReady
    }
    guard let serverPeer else {
      throw RouteError.noServer
    }
    let request = RouteToAVP(target: target)
    log.notice("""
      → SEND RouteToAVP to=\(serverPeer.description, privacy: .public) \
      filepath=\(target, privacy: .public)
      """)
    do {
      let reply: RouteToAVP.Reply =
      try await client.send(request, to: serverPeer)
      log.notice("""
        ← REPLY RouteToAVP from=\(serverPeer.description, privacy: .public) \
        accepted=\(reply.accepted, privacy: .public)
        """)
      return reply
    } catch {
      log.error("""
        ✗ SEND RouteToAVP to=\(serverPeer.description, privacy: .public) \
        error=\(String(reflecting: error), privacy: .public)
        """)
      throw error
    }
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
