import AppKit
import Foundation
import GalleyCoreKit
import GalleyServerKit
import KosmosCore
import KosmosTransport
import Observation
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "KosmosLink")

/// One per Server process. Owns the `KosmosClient`, the peer-role
/// mirror, and the per-window state for files currently displayed on
/// AVP. Built but not started by `AppModel.init`;
/// `AppModel.startServer()` calls `start()` after the preview server
/// is up so we have a port to publish on each `OpenDocument`.
///
/// When a `visionViewer` peer joins: switch the preview server to
/// LAN-reachable mode so AVP can dial the Server. Every subsequent
/// `OpenDocument` message ships the cert pin and the full LAN host
/// candidate list inline — no separate advertisement step.
///
/// When the last `visionViewer` peer leaves: revert to loopback,
/// walk the open-window set, and re-open each on the local
/// Galley.app via `URL.galleyRequest`.
///
/// The `RouteToAVP` request from a Mac Viewer peer is dispatched
/// through the same path Finder-opens take (`dispatchOpenURLToAVP`),
/// so the AVP-vs-Mac decision stays in one place.
@MainActor
@Observable
final class KosmosLink {
  /// Any peer is currently connected. Surfaced for legacy callers
  /// (UI binding etc.); newer code should branch on `isAVPReachable`.
  private(set) var isPeerConnected: Bool = false

  /// AVP currently reachable: at least one `visionViewer` peer is
  /// connected AND its last lifecycle message was a resume.
  private(set) var isAVPReachable: Bool = false

  /// HTTPS / HTTP listeners are bound. Settings-pill consumers read
  /// this. Driven by the preview server, surfaced here for
  /// convenience.
  private(set) var isAdvertising: Bool = false

  @ObservationIgnored private let deviceID: UUID
  @ObservationIgnored private var client: KosmosClient?
  @ObservationIgnored private var link: LoomKosmosLink?

  @ObservationIgnored private let server: PreviewServerController

  /// HTTP tunnel responder. Subscribes to `ProxyHTTPRequest` from AVP
  /// peers and streams responses chunkwise from the local Hummingbird
  /// HTTP listener over Kosmos.
  @ObservationIgnored private let httpTunnel: HTTPTunnelMacHandler

  /// Per-window state for files currently delegated to AVP.
  struct OpenWindow {
    let fileURL: URL
    let peerID: PeerID
    let watchTask: Task<Void, Never>
  }

  @ObservationIgnored private var openOnAVP: [KosmosCore.WindowID: OpenWindow]
  = [:]
  @ObservationIgnored private let windowIDAllocator = KosmosCore
    .WindowIDAllocator()

  /// Current peer role mirror, driven by `client.peers`.
  @ObservationIgnored private var peerRoles: [PeerID: GalleyKosmosRole] = [:]

  /// Per-peer "is this peer's app currently resumed?" flag. Set to
  /// `true` on join (peers are assumed reachable until they say
  /// otherwise), `false` on `AppWillSuspend`, `true` on `AppDidResume`.
  /// Read by `firstReachableVisionPeer` to gate routing — a suspended
  /// AVP looks like a connected peer at the Kosmos level (the TCP
  /// socket lingers when visionOS suspends the app with no scenes),
  /// so we need an in-band signal to know it's not actually draining
  /// its message queue.
  @ObservationIgnored private var peerResumed: [PeerID: Bool] = [:]

  @ObservationIgnored private var bootstrapTask: SubscriptionToken?
  @ObservationIgnored private var peerWatchTask: SubscriptionToken?
  @ObservationIgnored private var closeWindowSubscription: SubscriptionToken?
  @ObservationIgnored private var suspendSubscription: SubscriptionToken?
  @ObservationIgnored private var resumeSubscription: SubscriptionToken?
  @ObservationIgnored private var proxyRequestSubscription: SubscriptionToken?
  @ObservationIgnored private var proxyCancelSubscription: SubscriptionToken?

  init(server: PreviewServerController) {
    self.server = server
    self.deviceID = loadOrMakeGalleyDeviceID(role: .server)
    self.httpTunnel = HTTPTunnelMacHandler(
      upstreamBaseProvider: { Defaults.shared.serverEndpointURL })
  }

  /// Begin advertising. Idempotent. `httpURL` is the Server's loopback
  /// HTTP base URL once the listener has bound; it's published in the
  /// peer's Kosmos metadata so the Mac Viewer's pill can read the port
  /// for display without a side-channel file lookup. `nil` means the
  /// HTTP listener never came up — peers can still discover liveness
  /// but won't see a URL.
  func start(httpURL: URL?) {
    guard bootstrapTask == nil else { return }
    bootstrapTask = Task { [weak self] in
      await self?.bootstrap(httpURL: httpURL)
    }.token
  }

  func stop() {
    bootstrapTask = nil
    peerWatchTask = nil
    closeWindowSubscription = nil
    suspendSubscription = nil
    resumeSubscription = nil
    proxyRequestSubscription = nil
    proxyCancelSubscription = nil
    httpTunnel.stop()
    for (_, window) in openOnAVP {
      window.watchTask.cancel()
    }
    openOnAVP.removeAll()
    peerRoles.removeAll()
    peerResumed.removeAll()
    if let client {
      Task { await client.stop() }
    }
    client = nil
    link = nil
    isAdvertising = false
    isPeerConnected = false
    isAVPReachable = false
  }

  /// Called by `application(_:open:)` (and the Mac Viewer's
  /// `RouteToAVP` handler) when a file should be dispatched to AVP
  /// if possible. Returns true if dispatched; false if AVP is
  /// unavailable and the caller should fall back.
  func dispatchOpenURLToAVP(_ fileURL: GalleyBridgeRequest) async -> Bool {
    guard
      let client,
      let visionPeer = firstReachableVisionPeer()
    else {
      log.notice("""
        Cannot dispatch — no reachable vision peer for \
        \(fileURL, privacy: .public)
        """)
      return false
    }
    let windowID = trackOpenWindow(
      fileURL: fileURL.target.url,
      peerID: visionPeer,
      client: client)
    publishOpenDocument(
      fileURL: fileURL,
      windowID: windowID,
      client: client)
    return true
  }

  /// Allocates the per-window state and subscribes the watcher to the
  /// file. Each file-change event publishes a `WindowContentChanged`
  /// so AVP can reload the preview.
  private func trackOpenWindow(
    fileURL: URL,
    peerID: PeerID,
    client: KosmosClient
  ) -> KosmosCore.WindowID {
    let windowID = windowIDAllocator.next()
    let watcher = server.watcher
    let watchTask = Task { [weak client] in
      let changes = await watcher.subscribe(to: fileURL)
      for await _ in changes {
        log.notice("""
          → PUBLISH WindowContentChanged \
          window=\(windowID, privacy: .public) \
          file=\(fileURL.path, privacy: .public)
          """)
        await client?.publish(WindowContentChanged(windowID: windowID))
      }
    }
    openOnAVP[windowID] = OpenWindow(
      fileURL: fileURL, peerID: peerID, watchTask: watchTask)
    return windowID
  }

  /// Builds and publishes the `OpenDocument` Kosmos message and emits
  /// the corresponding diagnostic log line.
  private func publishOpenDocument(
    fileURL: GalleyBridgeRequest,
    windowID: KosmosCore.WindowID,
    client: KosmosClient
  ) {
    // The data plane rides Kosmos via `ProxyHTTPRequest` — AVP
    // synthesizes its own `galley://preview/<path>` URL from
    // `documentPath` and tunnels each subresource fetch back through
    // the `HTTPTunnelMacHandler` over Kosmos.
    let message = OpenDocument(
      docID: windowID,
      documentPath: fileURL.target.url.path,
      displayName: fileURL.target.url.lastPathComponent,
      scrollLineHint: fileURL.target.scrollLine,
      openBehavior: .newWindow)
    log.notice("""
      → PUBLISH OpenDocument doc=\(windowID, privacy: .public) \
      path=\(message.documentPath, privacy: .public) \
      name=\(message.displayName, privacy: .public)
      """)
    Task { [weak client] in
      await client?.publish(message)
    }
  }

  // MARK: - Bootstrap

  private func bootstrap(httpURL: URL?) async {
    var metadata: [String: String] = [:]
    if let httpURL {
      metadata[GalleyKosmosMetadataKey.httpURL] = httpURL.absoluteString
    }
    let (client, link) = await makeGalleyKosmosClient(
      role: .server, deviceID: deviceID, extraMetadata: metadata)
    self.client = client
    self.link = link

    await registerHandlers(client: client)
    startPeerWatch(client: client)
    startSubscriptions(client: client)

    do {
      try await link.start()
      isAdvertising = true
      log.notice("Kosmos link started.")
    } catch {
      isAdvertising = false
      log.error("""
        Kosmos link failed to start: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  public static func openInLocalGalleyApp(_ fileURL: GalleyBridgeRequest) {
    NSWorkspace.shared.open(GalleyRequest.document(fileURL.target).url)
  }

  @MainActor
  @discardableResult
  public static func dispatchOpenURL(
    _ url: GalleyBridgeRequest, with kosmos: KosmosLink?) async -> Bool
  {
    // AVP reachable over Kosmos → dispatch and we're done.
    // Otherwise (no peer, or peer suspended per `peerResumed`) the
    // doc opens in local Galley.app. AVP shows up automatically the
    // next time the user activates Galley on AVP — the peer reconnects
    // and subsequent opens land there again.
    if await kosmos?.dispatchOpenURLToAVP(url) == true {
      return true
    }
    Self.openInLocalGalleyApp(url)
    return false
  }

  private func registerHandlers(client: KosmosClient) async {
    // RouteToAVP: Mac Viewer asks "open this file wherever's best."
    // Reuses the same dispatch path Finder-opens use so the
    // AVP-vs-Mac decision stays in one place (Pillar 4).
    await client.handle(
      RouteToAVP.self
    ) { [weak self] sender, request -> RouteToAVP.Reply in
      log.notice("""
        ← HANDLE RouteToAVP from=\(sender.description, privacy: .public) \
        filepath=\(request.target, privacy: .public)
        """)
      let dispatched = await Self.dispatchOpenURL(
        GalleyBridgeRequest(target: request.target), with: self
      )
      log.notice("""
        → REPLY RouteToAVP to=\(sender.description, privacy: .public) \
        accepted=\(dispatched, privacy: .public)
        """)
      return RouteToAVP.Reply(accepted: dispatched)
    }
  }

  private func startPeerWatch(client: KosmosClient) {
    peerWatchTask = Task { [weak self] in
      for await snapshot in client.peers {
        await MainActor.run {
          self?.handlePeersChanged(snapshot)
        }
      }
    }.token
  }

  private func startSubscriptions(client: KosmosClient) {
    closeWindowSubscription = client
      .subscribe(CloseWindow.self) { [weak self] sender, message in
        log.notice("""
          ← RECV CloseWindow from=\(sender.description, privacy: .public) \
          window=\(message.windowID, privacy: .public)
          """)
        self?.handleCloseWindow(message)
      }

    suspendSubscription = client
      .subscribe(AppWillSuspend.self) { [weak self] sender, _ in
        log.notice("""
          ← RECV AppWillSuspend from=\(sender.description, privacy: .public)
          """)
        self?.setPeerResumed(sender, resumed: false)
      }

    resumeSubscription = client
      .subscribe(AppDidResume.self) { [weak self] sender, _ in
        log.notice("""
          ← RECV AppDidResume from=\(sender.description, privacy: .public)
          """)
        self?.setPeerResumed(sender, resumed: true)
      }

    proxyRequestSubscription = client
      .subscribe(ProxyHTTPRequest.self) { [weak self, weak client] _, request in
        guard let self, let client else { return }
        self.httpTunnel.handleRequest(request, client: client)
      }

    proxyCancelSubscription = client
      .subscribe(ProxyHTTPCancel.self) { [weak self] _, message in
        self?.httpTunnel.handleCancel(message)
      }
  }

  private func setPeerResumed(_ peer: PeerID, resumed: Bool) {
    peerResumed[peer] = resumed
    updateReachabilityFlag()
  }

  // MARK: - Peer state

  private func handlePeersChanged(_ snapshot: [PeerID: PeerInfo]) {
    let previousRoles = peerRoles
    var newRoles: [PeerID: GalleyKosmosRole] = [:]
    for (id, info) in snapshot {
      if let role = info.galleyRole {
        newRoles[id] = role
      }
    }
    peerRoles = newRoles
    isPeerConnected = !newRoles.isEmpty

    // Dump the raw snapshot — including peers with nil role — so a
    // "Mac Viewer sees AVP, Server doesn't" mismatch is diagnosable
    // by eye. A peer that's discovered without role metadata
    // (TXT-record race) is filtered out of `peerRoles` and would
    // otherwise be invisible to logs.
    let summary = snapshot.values
      .map { info in
        let role = info.galleyRole?.rawValue ?? "nil"
        return "\(info.id.description)[role=\(role)]"
      }
      .sorted()
      .joined(separator: ", ")
    log.notice("""
      peer-snapshot count=\(snapshot.count, privacy: .public) \
      peers=[\(summary, privacy: .public)]
      """)

    let newVisionPeers = Set(newRoles.filter { $0.value == .visionViewer }
      .map(\.key))
    let oldVisionPeers = Set(previousRoles.filter { $0.value == .visionViewer }
      .map(\.key))

    for peer in newVisionPeers.subtracting(oldVisionPeers) {
      Task { await self.onVisionPeerJoined(peer) }
    }
    for peer in oldVisionPeers.subtracting(newVisionPeers) {
      onVisionPeerLeft(peer)
    }

    updateReachabilityFlag()
  }

  private func onVisionPeerJoined(_ peer: PeerID) async {
    log.notice("Vision peer joined: \(peer.description, privacy: .public)")
    // Assume the AVP is resumed when it first connects. Subsequent
    // `AppWillSuspend` / `AppDidResume` lifecycle messages correct
    // this; in their absence "connected = resumed" is the right
    // default (the peer wouldn't have completed the Kosmos handshake
    // if its app weren't running).
    peerResumed[peer] = true
    updateReachabilityFlag()
    // No bind-mode flip: the Mac HTTP listener stays loopback-only
    // for AVP and every other consumer. AVP traffic rides the
    // Kosmos tunnel via `HTTPTunnelMacHandler`.
  }

  private func onVisionPeerLeft(_ peer: PeerID) {
    log.notice("Vision peer left: \(peer.description, privacy: .public)")
    peerResumed.removeValue(forKey: peer)
    updateReachabilityFlag()

    // Migrate windows that were on this peer back to Mac.
    let toMigrate = openOnAVP.filter { $0.value.peerID == peer }
    for (windowID, window) in toMigrate {
      openOnAVP.removeValue(forKey: windowID)
      window.watchTask.cancel()
      log.notice("""
        Migrating to Mac: \(window.fileURL.path, privacy: .public)
        """)
      Self.openInLocalGalleyApp(
        GalleyBridgeRequest(target: DocumentTarget(url: window.fileURL)))
    }
  }

  private func handleCloseWindow(_ message: CloseWindow) {
    if let window = openOnAVP.removeValue(forKey: message.windowID) {
      window.watchTask.cancel()
    }
    log.debug("CloseWindow \(message.windowID, privacy: .public)")
  }

  // MARK: - Helpers

  /// First `visionViewer` peer that's connected AND currently
  /// resumed. Suspended peers (AVP whose scenes are all gone — the
  /// OS suspended the process even though the Kosmos TCP socket
  /// lingers) are excluded so dispatches don't land in a process
  /// that can't drain its message queue.
  private func firstReachableVisionPeer() -> PeerID? {
    peerRoles.first { id, role in
      role == .visionViewer && peerResumed[id] == true
    }?.key
  }

  private func updateReachabilityFlag() {
    isAVPReachable = firstReachableVisionPeer() != nil
  }

}

/// Pure normalization of inbound URLs from `application(_:open:)` and
/// the custom `galley://` scheme into the canonical file URL the
/// dispatch pipeline expects.
///
/// `galley://settings` is recognized and surfaced separately so the
/// caller can route it to SwiftUI's `openSettings()` instead of
/// trying to open it as a document.

/// URL scheme used by `Galley.app` (Viewer) to hand a file back to
/// `Galley Server.app` for AVP dispatch. The inverse direction of
/// `galley://` (which Server uses to hand a file to the Viewer).
///
/// Why a custom scheme instead of
/// `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`:
/// the workspace API returns success without delivering
/// `kAEOpenDocuments` to the target's `application(_:open:)` —
/// observed live; the completion handler's `app` is the target PID
/// with `error=nil`, but the target never sees the URL. Routing by
/// URL scheme avoids the cross-process AppleEvent delivery
/// altogether: LaunchServices hands the URL to Server's
/// `application(_:open:)` directly.
public struct GalleyBridgeRequest: Sendable, Equatable,
                                   CustomStringConvertible
{
  public static let scheme = "galley-bridge"

  public let target: DocumentTarget

  public var description: String {
    url.absoluteString
  }

  public init(target: DocumentTarget) {
    self.target = target
  }

  public init?(from url: URL) {
    guard url.scheme?.lowercased() == Self.scheme
    else { return nil }
    let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false)
    guard let target = DocumentTarget.init(components: components)
    else { return nil }
    self.target = target
  }

  public var url: URL {
    target.url(scheme: Self.scheme)
  }
}
