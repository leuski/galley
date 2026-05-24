import AppKit
import Foundation
import GalleyCoreKit
import GalleyServerKit
import KosmosBridge
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
/// is up so we have a port to advertise.
///
/// When a `visionViewer` peer joins: switch the preview server to
/// LAN-reachable mode, publish `BridgeAdvertisement` so AVP knows
/// the cert pin + base URL.
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

  @ObservationIgnored private let identityStore: BridgeIdentityStore
  @ObservationIgnored private let server: PreviewServerController

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

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var peerWatchTask: Task<Void, Never>?
  @ObservationIgnored
  private var closeWindowSubscriptionTask: Task<Void, Never>?

  init(
    server: PreviewServerController,
    identityStore: BridgeIdentityStore
  ) {
    self.server = server
    self.identityStore = identityStore
    self.deviceID = loadOrMakeGalleyDeviceID(role: .server)
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
    }
  }

  func stop() {
    bootstrapTask?.cancel()
    bootstrapTask = nil
    peerWatchTask?.cancel()
    peerWatchTask = nil
    closeWindowSubscriptionTask?.cancel()
    closeWindowSubscriptionTask = nil
    for (_, window) in openOnAVP {
      window.watchTask.cancel()
    }
    openOnAVP.removeAll()
    peerRoles.removeAll()
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
      let resolved = await resolveAVPDispatch(fileURL: fileURL)
    else { return false }
    let windowID = trackOpenWindow(
      fileURL: fileURL.target.url,
      peerID: resolved.visionPeer,
      client: client)
    publishOpenDocument(
      fileURL: fileURL,
      identity: resolved.identity,
      previewURL: resolved.previewURL,
      windowID: windowID,
      client: client)
    return true
  }

  /// Bundle of resolved preconditions returned by
  /// `resolveAVPDispatch`. Kept as a named type instead of a 3-tuple
  /// for readability and SwiftLint's large_tuple rule.
  private struct ResolvedDispatch {
    let visionPeer: PeerID
    let identity: BridgeIdentity
    let previewURL: URL
  }

  /// Preconditions for an AVP dispatch: a reachable vision peer, a
  /// bridge identity, and an HTTPS-only preview URL on the LAN. Logs
  /// the failure mode and returns nil when any one is missing.
  private func resolveAVPDispatch(
    fileURL: GalleyBridgeRequest
  ) async -> ResolvedDispatch? {
    guard let visionPeer = firstReachableVisionPeer() else {
      log.notice("""
        Cannot dispatch — no reachable vision peer for \
        \(fileURL, privacy: .public)
        """)
      return nil
    }
    let identity: BridgeIdentity
    do {
      identity = try await identityStore.currentIdentity()
    } catch {
      log.error("""
        Cannot dispatch — bridge identity unavailable: \
        \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
    let reachable = LANHostDiscovery.reachableHosts()
    let lanHost = BridgeURLBuilder.preferredAVPHost(from: reachable)
    let httpsPort = ServerPortFile.https.read()
    guard let base = BridgeURLBuilder.avpDocumentURL(
      host: lanHost,
      httpsPort: httpsPort,
      compose: Self.composeLANURL)
    else {
      let hostStr = lanHost ?? "nil"
      let portStr = httpsPort.map(String.init) ?? "nil"
      log.error("""
        Cannot dispatch — HTTPS not bound on LAN \
        (host=\(hostStr, privacy: .public) \
        httpsPort=\(portStr, privacy: .public)). \
        Refusing HTTP fallback — HTTP listener is loopback-only.
        """)
      return nil
    }
    return ResolvedDispatch(
      visionPeer: visionPeer,
      identity: identity,
      previewURL: base.appendingPreview(fileURL.target.url))
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
    identity: BridgeIdentity,
    previewURL: URL,
    windowID: KosmosCore.WindowID,
    client: KosmosClient
  ) {
    let message = OpenDocument(
      docID: windowID,
      httpsURL: previewURL,
      certificateSHA256: identity.certificateSHA256,
      displayName: fileURL.target.url.lastPathComponent,
      scrollLineHint: fileURL.target.scrollLine,
      openBehavior: .newWindow)
    let pinHex = identity.certificateSHA256.map {
      String(format: "%02x", $0)
    }.joined()
    log.notice("""
      → PUBLISH OpenDocument doc=\(windowID, privacy: .public) \
      url=\(previewURL.absoluteString, privacy: .public) \
      name=\(message.displayName, privacy: .public) \
      certSHA256=\(pinHex, privacy: .public) \
      file=\(fileURL, privacy: .public)
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
    let dispatched = await kosmos?.dispatchOpenURLToAVP(url) ?? false
    if !dispatched {
      Self.openInLocalGalleyApp(url)
    }
    return dispatched
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
    }
  }

  private func startSubscriptions(client: KosmosClient) {
    closeWindowSubscriptionTask = Task { [weak self] in
      let stream = client.subscribe(CloseWindow.self)
      for await (sender, message) in stream {
        log.notice("""
          ← RECV CloseWindow from=\(sender.description, privacy: .public) \
          window=\(message.windowID, privacy: .public)
          """)
        await MainActor.run {
          self?.handleCloseWindow(message)
        }
      }
    }
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
    updateReachabilityFlag()

    let extras = Set(LANHostDiscovery.reachableHosts())
    server.setBindMode(.lanReachable(extraAllowedHostnames: extras))

    do {
      let identity = try await identityStore.currentIdentity()
      guard let base = BridgeURLBuilder.advertisementURL(
        host: LANHostDiscovery.reachableHosts().first,
        httpPort: ServerPortFile.http.read(),
        httpsPort: ServerPortFile.https.read(),
        compose: Self.composeLANURL)
      else {
        log.error("No LAN base URL to advertise.")
        return
      }
      let advertisement = BridgeAdvertisement(
        certificateSHA256: identity.certificateSHA256,
        baseURL: base)
      let allowedHosts = LANHostDiscovery.reachableHosts()
        .joined(separator: ",")
      let pinHex = identity.certificateSHA256.map {
        String(format: "%02x", $0)
      }.joined()
      log.notice("""
        → PUBLISH BridgeAdvertisement \
        base=\(base.absoluteString, privacy: .public) \
        certSHA256=\(pinHex, privacy: .public) \
        allowedHosts=\(allowedHosts, privacy: .public)
        """)
      // Broadcast — peers that don't care (Mac Viewer) just ignore.
      // The vision peer's subscribe(BridgeAdvertisement.self) picks
      // it up regardless of when it joined relative to the publish.
      await client?.publish(advertisement)
    } catch {
      log.error("""
        BridgeAdvertisement publish failed: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  private func onVisionPeerLeft(_ peer: PeerID) {
    log.notice("Vision peer left: \(peer.description, privacy: .public)")
    let stillHaveVision = peerRoles.contains { $0.value == .visionViewer }
    if !stillHaveVision {
      server.setBindMode(.loopback)
    }
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

  /// First `visionViewer` peer in the snapshot. Reachability is
  /// purely peer-set membership now — if AVP's Kosmos session is up,
  /// AVP can receive messages, period. Earlier code gated on
  /// `AppWillSuspend` / `AppDidResume` lifecycle messages, but
  /// visionOS scene phase fires `.background` for plain focus loss
  /// and would disable the menu while a viewer window was still
  /// visible. Removed.
  private func firstReachableVisionPeer() -> PeerID? {
    peerRoles.first { _, role in role == .visionViewer }?.key
  }

  private func updateReachabilityFlag() {
    isAVPReachable = firstReachableVisionPeer() != nil
  }

  /// Adapter between `BridgeURLBuilder.Composer` (unlabeled, UInt16
  /// port) and `LANHostDiscovery.composeURL` (labeled, Int port). Kept
  /// here so the builder stays free of the IPv6-bracketing dep.
  private static func composeLANURL(
    _ scheme: String, _ host: String, _ port: UInt16
  ) -> URL? {
    LANHostDiscovery.composeURL(
      scheme: scheme, host: host, port: Int(port))
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
