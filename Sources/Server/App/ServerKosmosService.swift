import AppKit
import Foundation
import GalleyCoreKit
import GalleyServerKit
import KosmosCore
import KosmosHTTPTunnel
import KosmosTransport
import Observation
import OSLog
import KosmosAppKit

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
  /// Any peer is currently connected. Forwarded from the tracker for
  /// legacy callers; newer code should branch on `isAVPReachable`.
  var isPeerConnected: Bool { reachability.isPeerConnected }

  /// AVP currently reachable: a `visionViewer` peer is connected AND
  /// its last lifecycle message was a resume.
  var isAVPReachable: Bool { reachability.isAVPReachable }

  @ObservationIgnored private let host = ServiceHost(role: .server)
  @ObservationIgnored private let server: PreviewServerController

  /// Shared peer-role mirror + AVP reachability state machine. Vision
  /// join/leave is routed back here to start/stop file delegation.
  /// `@ObservationIgnored` keeps the `@Observable` macro from rewriting
  /// this `lazy` stored property into a computed one (the closures
  /// capture `self`, so it must stay lazy); reads of the tracker's own
  /// observable state still invalidate observers because it is
  /// `@Observable`.
  @ObservationIgnored
  private lazy var reachability = PeerReachabilityTracker<GalleyKosmosRole>(
    roleOf: { $0.galleyRole },
    onVisionPeerJoined: { [weak self] peer in self?.onVisionPeerJoined(peer) },
    onVisionPeerLeft: { [weak self] peer in self?.onVisionPeerLeft(peer) })

  /// HTTP tunnel responder. Subscribes to `ProxyHTTPRequest` from AVP
  /// peers and streams responses chunkwise from the local HTTP
  /// listener over Kosmos.
  @ObservationIgnored private let httpTunnelResponder: Responder

  /// Server's loopback HTTP base URL, captured at `start(httpURL:)`
  /// time and read inside `makeLink()` to populate advertise-time
  /// metadata. `nil` if the listener hadn't bound by `start()`.
  @ObservationIgnored private var advertisedHTTPURL: URL?

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

  init(server: PreviewServerController) {
    self.server = server
    self.httpTunnelResponder = Responder(
      upstreamBaseProvider: { Defaults.shared.serverEndpointURL })
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
    for (_, window) in openOnAVP {
      window.watchTask.cancel()
    }
    openOnAVP.removeAll()
    Task { await host.stop() }
  }

  // MARK: - KosmosService

  func makeLink() async -> KosmosClient {
    await host.makeLink(
      extraMetadata: advertisedHTTPURL.map {
        [GalleyKosmosMetadataKey.httpURL: $0.absoluteString]
      } ?? [:])
  }

  func configure(host: ServiceHost, client: KosmosClient) async {
    await registerHandlers(host: host, client: client)
    httpTunnelResponder.install(on: host, client: client)
    reachability.installLifecycleObservers(on: host)
    host.subscribe(CloseWindow.self) { [weak self] sender, message in
      log.notice("""
        ← RECV CloseWindow from=\(sender.description, privacy: .public) \
        window=\(message.windowID, privacy: .public)
        """)
      self?.handleCloseWindow(message)
    }
  }

  func peersChanged(_ snapshot: [PeerID: PeerInfo]) {
    // Dump the raw snapshot — including peers with nil role — so a
    // "Mac Viewer sees AVP, Server doesn't" mismatch is diagnosable by
    // eye. A peer discovered without role metadata (TXT-record race) is
    // filtered out of the tracker and would otherwise be invisible.
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
    reachability.update(snapshot)
  }

  func linkDidStart(_ error: (any Error)?) {
    if let error {
      log.error("""
        Kosmos link failed to start: \
        \(error.localizedDescription, privacy: .public)
        """)
    } else {
      log.notice("Kosmos link started.")
    }
  }

  /// Called by `application(_:open:)` (and the Mac Viewer's
  /// `RouteToAVP` handler) when a file should be dispatched to AVP if
  /// possible. Returns true if dispatched; false if AVP is unavailable
  /// and the caller should fall back.
  func dispatchOpenURLToAVP(_ fileURL: GalleyBridgeRequest) async -> Bool {
    guard
      let client = host.client,
      let visionPeer = reachability.firstReachableVisionPeer
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
    // the `Responder` over Kosmos.
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

  public static func openInLocalGalleyApp(_ fileURL: GalleyBridgeRequest) {
    NSWorkspace.shared.open(GalleyRequest.document(fileURL.target).url)
  }

  @MainActor
  @discardableResult
  public static func dispatchOpenURL(
    _ url: GalleyBridgeRequest, with kosmos: ServerKosmosService?) async -> Bool
  {
    // AVP reachable over Kosmos → dispatch and we're done. Otherwise
    // (no peer, or peer suspended) the doc opens in local Galley.app.
    // AVP shows up automatically the next time the user activates
    // Galley on AVP — the peer reconnects and subsequent opens land
    // there again.
    if await kosmos?.dispatchOpenURLToAVP(url) == true {
      return true
    }
    Self.openInLocalGalleyApp(url)
    return false
  }

  // MARK: - Subscription wiring

  private func registerHandlers(
    host: ServiceHost, client: KosmosClient
  ) async {
    // RouteToAVP: Mac Viewer asks "open this file wherever's best."
    // Reuses the same dispatch path Finder-opens use so the AVP-vs-Mac
    // decision stays in one place.
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

  // MARK: - Vision peer lifecycle (driven by the reachability tracker)

  private func onVisionPeerJoined(_ peer: PeerID) {
    log.notice("Vision peer joined: \(peer.description, privacy: .public)")
    // No bind-mode flip: the Mac HTTP listener stays loopback-only for
    // AVP and every other consumer. AVP traffic rides the Kosmos tunnel
    // via `Responder`. The resumed flag is seeded by the tracker.
  }

  private func onVisionPeerLeft(_ peer: PeerID) {
    log.notice("Vision peer left: \(peer.description, privacy: .public)")
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
}
