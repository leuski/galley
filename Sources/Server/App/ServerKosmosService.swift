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
  /// AVP currently reachable: a same-product `vision` peer is connected
  /// AND its last lifecycle message was a resume. Resolved by the host.
  var isAVPReachable: Bool { host.reachablePeer(deviceType: .vision) != nil }

  @ObservationIgnored private let host = ServiceHost(role: .server)
  @ObservationIgnored private let server: PreviewServerController

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
    await host.makeLink(extraMetadata: [.httpURL => advertisedHTTPURL])
  }

  func configure(host: ServiceHost, client: KosmosClient) async {
    await registerHandlers(host: host)
    httpTunnelResponder.install(on: host, client: client)
    // Lifecycle (AppWillSuspend/Resume) reachability gating, and the
    // `← RECV` logging below, are wired by the host itself.
    host.subscribe(CloseWindow.self) { [weak self] _, message in
      self?.handleCloseWindow(message)
    }
  }

  func peersChanged(_ snapshot: [PeerID: PeerInfo]) {
    // The host logs the snapshot and mirrors reachability; the Server's
    // only reaction is to migrate any windows back to the Mac when the
    // AVP they were delegated to drops out of the peer set.
    migrateWindowsForDepartedPeers(present: Set(snapshot.keys))
  }

  /// Called by `application(_:open:)` (and the Mac Viewer's
  /// `RouteToAVP` handler) when a file should be dispatched to AVP if
  /// possible. Returns true if dispatched; false if AVP is unavailable
  /// and the caller should fall back.
  func dispatchOpenURLToAVP(_ fileURL: GalleyBridgeRequest) async -> Bool {
    guard let visionPeer = host.reachablePeer(deviceType: .vision) else {
      log.notice("""
        Cannot dispatch — no reachable vision peer for \
        \(fileURL, privacy: .public)
        """)
      return false
    }
    let windowID = trackOpenWindow(
      fileURL: fileURL.target.documentURL, peerID: visionPeer)
    publishOpenDocument(fileURL: fileURL, windowID: windowID)
    return true
  }

  /// Allocates the per-window state and subscribes the watcher to the
  /// file. Each file-change event publishes a `WindowContentChanged`
  /// (logged by the host) so AVP can reload the preview.
  private func trackOpenWindow(
    fileURL: URL,
    peerID: PeerID
  ) -> KosmosCore.WindowID {
    let windowID = windowIDAllocator.next()
    let watcher = server.watcher
    let watchTask = Task { @MainActor [weak self] in
      let changes = await watcher.subscribe(to: fileURL)
      for await _ in changes {
        self?.host.publish(WindowContentChanged(windowID: windowID))
      }
    }
    openOnAVP[windowID] = OpenWindow(
      fileURL: fileURL, peerID: peerID, watchTask: watchTask)
    return windowID
  }

  /// Publishes the `OpenDocument` for a freshly-delegated window. The
  /// data plane rides Kosmos via `ProxyHTTPRequest` — AVP synthesizes
  /// its own `galley://preview/<path>` URL from `documentPath` and
  /// tunnels each subresource fetch back through the `Responder`.
  private func publishOpenDocument(
    fileURL: GalleyBridgeRequest,
    windowID: KosmosCore.WindowID
  ) {
    host.publish(OpenDocument(
      docID: windowID,
      documentPath: fileURL.target.documentURL.path,
      displayName: fileURL.target.documentURL.lastPathComponent,
      scrollLineHint: fileURL.target.scrollLine,
      openBehavior: .newWindow))
  }

  public static func openInLocalGalleyApp(_ request: GalleyBridgeRequest) {
    OpenDocumentActivity(target: request.target).open()
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

  private func registerHandlers(host: ServiceHost) async {
    // RouteToAVP: Mac Viewer asks "open this file wherever's best."
    // Reuses the same dispatch path Finder-opens use so the AVP-vs-Mac
    // decision stays in one place. The host logs the request and reply.
    await host.handle(RouteToAVP.self)
    { [weak self] _, request -> RouteToAVP.Reply in
      let dispatched = await Self.dispatchOpenURL(
        GalleyBridgeRequest(target: request.target), with: self
      )
      return RouteToAVP.Reply(accepted: dispatched)
    }
  }

  // MARK: - Window migration

  /// When an AVP peer we've delegated windows to drops out of the peer
  /// set, re-open those documents on the local Mac. Driven by
  /// `peersChanged` — the Server tracks which peer each window lives on,
  /// so a simple set-difference against the live peers replaces the old
  /// join/leave callback bookkeeping. (No bind-mode flip on join: the
  /// Mac HTTP listener stays loopback-only; AVP traffic rides the Kosmos
  /// tunnel via `Responder`.)
  private func migrateWindowsForDepartedPeers(present: Set<PeerID>) {
    let toMigrate = openOnAVP.filter { !present.contains($0.value.peerID) }
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
