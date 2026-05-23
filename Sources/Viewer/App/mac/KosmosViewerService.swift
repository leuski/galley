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
@MainActor
@Observable
final class KosmosViewerService {
  /// Snapshot of peers visible to Kosmos.
  private(set) var peers: [PeerID: PeerInfo] = [:]

  /// True once `link.start()` returned successfully. Stays true even
  /// if every peer subsequently leaves — failures show up as
  /// `lastStartError`, not as `isLinkRunning` flipping back.
  private(set) var isLinkRunning: Bool = false

  /// Last error encountered during `link.start()`, if any. Surfaced
  /// in Settings so the user can tell a "no peer discovered" pill
  /// (probably Local Network permission, or the Server isn't really
  /// up) apart from a "link failed to advertise" pill.
  private(set) var lastStartError: String?

  /// `kosmos.host` of this Mac, used to recognise the local Server
  /// out of any other Servers reachable on the network.
  @ObservationIgnored private let localHostUUID: String? =
    KosmosLocalHostID.current

  @ObservationIgnored private let deviceID: UUID
  @ObservationIgnored private var client: KosmosClient?
  @ObservationIgnored private var link: LoomKosmosLink?

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var peerWatchTask: Task<Void, Never>?

  init() {
    self.deviceID = loadOrMakeGalleyDeviceID(role: .macViewer)
  }

  /// Begin advertising. Idempotent.
  func start() {
    guard bootstrapTask == nil else { return }
    bootstrapTask = Task { [weak self] in
      await self?.bootstrap()
    }
  }

  func stop() async {
    bootstrapTask?.cancel()
    bootstrapTask = nil
    peerWatchTask?.cancel()
    peerWatchTask = nil
    if let client {
      await client.stop()
    }
    client = nil
    link = nil
    peers = [:]
  }

  // MARK: - Derived state

  /// First reachable Server whose `kosmos.host` matches this Mac's.
  /// Peers with the same role on other Macs are visible in
  /// `client.peers` but ignored here so the pill / menu don't track
  /// strangers.
  var serverPeer: PeerID? {
    GalleyPeerClassifier.serverPeer(
      in: peers, localHostUUID: localHostUUID)
  }

  /// First reachable AVP. Reachability is purely peer-set membership
  /// — if AVP's Kosmos session is up, AVP can receive. Earlier code
  /// gated on `AppWillSuspend` / `AppDidResume` lifecycle messages,
  /// but visionOS scene phase fires `.background` for focus blips
  /// that aren't real suspension and would disable the menu while a
  /// viewer window was visibly open.
  var avpPeer: PeerID? {
    GalleyPeerClassifier.avpPeer(in: peers)
  }

  /// Drives the Server-status pill.
  var isServerPeerConnected: Bool { serverPeer != nil }

  /// HTTP base URL the Server published in its peer metadata at
  /// advertise time. `nil` until the Server peer appears with a URL
  /// in metadata. Drives the port number shown in `.running` pill text.
  var serverPeerHTTPURL: URL? {
    guard let id = serverPeer, let info = peers[id] else { return nil }
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
    guard let client else {
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
    /// been called, or its `bootstrap` Task is still pending.
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

  // MARK: - Bootstrap

  private func bootstrap() async {
    let (client, link) = await makeGalleyKosmosClient(
      role: .macViewer, deviceID: deviceID)
    self.client = client
    self.link = link

    startPeerWatch(client: client)

    do {
      try await link.start()
      isLinkRunning = true
      lastStartError = nil
      let identity = await client.identity.description
      log.notice("""
        Kosmos link started identity=\(identity, privacy: .public)
        """)
    } catch {
      isLinkRunning = false
      lastStartError = error.localizedDescription
      log.error("""
        Kosmos link failed to start: \
        \(error.localizedDescription, privacy: .public). \
        Check Console.app for subsystem net.leuski.galley, and \
        verify Local Network permission for Galley in System Settings.
        """)
    }
  }

  private func startPeerWatch(client: KosmosClient) {
    peerWatchTask = Task { [weak self] in
      for await snapshot in client.peers {
        await MainActor.run {
          self?.applyPeerSnapshot(snapshot)
        }
      }
    }
  }

  private func applyPeerSnapshot(_ snapshot: [PeerID: PeerInfo]) {
    peers = snapshot

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
}
#endif
