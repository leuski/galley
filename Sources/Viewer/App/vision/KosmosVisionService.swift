#if os(visionOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosTransport
import Observation
import OSLog
import SwiftUI

private let log = Logger(
  subsystem: bundleIdentifier, category: "KosmosVisionService")

/// AVP-side Kosmos surface. Owns a single `KosmosTransport.KosmosClient`
/// advertising as a `visionViewer`, mirrors the discovered peer set,
/// subscribes to bridge messages (open-document, content changes), and
/// publishes lifecycle to the bridge so the Mac can gate AVP
/// reachability on suspend / resume.
///
/// Also owns the AVP end of the HTTP tunnel — every `galley://` URL
/// the WebView fetches becomes a `ProxyHTTPRequest` Kosmos broadcast,
/// and the response chunks are routed back through
/// `HTTPTunnelAVPClient`. The service is the single subscription point
/// for the two response message types so we don't spin up a per-request
/// subscription.
@MainActor
@Observable
final class KosmosVisionService {
  /// Snapshot of peers visible to Kosmos. Other code (settings,
  /// debugging) can observe this; the service itself doesn't branch
  /// on it.
  private(set) var peers: [PeerID: PeerInfo] = [:]

  /// AVP-side HTTP tunnel client. Exposed so `WebPage` configuration
  /// can hand it to the `KosmosTunnelSchemeHandler` it installs on
  /// the `galley://` scheme.
  let httpTunnel: HTTPTunnelAVPClient

  @ObservationIgnored private let deviceID: UUID
  @ObservationIgnored private var client: KosmosClient?
  @ObservationIgnored private var link: LoomKosmosLink?

  @ObservationIgnored private var bootstrapTask: SubscriptionToken?
  @ObservationIgnored private var peerWatchTask: SubscriptionToken?
  @ObservationIgnored private var openURLSubscription: SubscriptionToken?
  @ObservationIgnored private var openDocumentSubscription: SubscriptionToken?
  @ObservationIgnored private var contentChangeSubscription: SubscriptionToken?
  @ObservationIgnored private var proxyHeadSubscription: SubscriptionToken?
  @ObservationIgnored private var proxyChunkSubscription: SubscriptionToken?

  /// Handler for incoming `OpenURL` / `OpenDocument` messages — wired
  /// by the app to call `openWindow(value: url)`. The service holds
  /// the closure rather than owning a SwiftUI environment value
  /// because `openWindow` is only available inside view bodies.
  @ObservationIgnored var onOpenURL: (@MainActor (URL) -> Void)?

  /// Per-window reload handlers. The document view registers on
  /// appearance, unregisters on disappearance.
  @ObservationIgnored
  private var reloadHandlers: [KosmosCore.WindowID: @MainActor () -> Void] = [:]
  @ObservationIgnored
  private var openWindows: [KosmosCore.WindowID: URL] = [:]

  init() {
    self.deviceID = loadOrMakeGalleyDeviceID(role: .visionViewer)
    self.httpTunnel = HTTPTunnelAVPClient(client: nil)
  }

  /// Begin advertising and browsing. Idempotent.
  func start() {
    guard bootstrapTask == nil else { return }
    bootstrapTask = Task { [weak self] in
      await self?.bootstrap()
    }.token
  }

  func stop() async {
    bootstrapTask = nil
    peerWatchTask = nil
    openURLSubscription = nil
    openDocumentSubscription = nil
    contentChangeSubscription = nil
    proxyHeadSubscription = nil
    proxyChunkSubscription = nil
    httpTunnel.stopAll()
    if let client {
      await client.stop()
    }
    client = nil
    link = nil
    reloadHandlers.removeAll()
    openWindows.removeAll()
    peers = [:]
  }

  /// Notify the Mac that AVP is about to suspend (`scenePhase`
  /// transitioned to `.background` — typically the user closed the
  /// last AVP Galley window including the anchor). Mac side flips the
  /// per-peer resumed flag and falls back to local Galley.app for
  /// subsequent opens until `publishResume` fires.
  func publishSuspend() {
    let message = AppWillSuspend(
      appID: Self.galleyAppID,
      deviceID: DeviceID(deviceID))
    log.notice("→ PUBLISH AppWillSuspend")
    Task { [weak client] in
      await client?.publish(message)
    }
  }

  /// Notify the Mac that AVP is serviceable again.
  func publishResume() {
    let message = AppDidResume(
      appID: Self.galleyAppID,
      deviceID: DeviceID(deviceID))
    log.notice("→ PUBLISH AppDidResume")
    Task { [weak client] in
      await client?.publish(message)
    }
  }

  /// Galley's wire AppID. Reverse-DNS, matches the Server's bundle
  /// identifier (the Server is the bridge — `appID` identifies the
  /// product, not the publishing endpoint).
  private static let galleyAppID = AppID(GalleyConstants.suiteName)

  /// Notify the Mac that the user closed a window on AVP.
  func notifyWindowClosed(_ windowID: KosmosCore.WindowID) {
    openWindows.removeValue(forKey: windowID)
    reloadHandlers.removeValue(forKey: windowID)
    let message = CloseWindow(windowID: windowID)
    log.notice("""
      → PUBLISH CloseWindow window=\(windowID, privacy: .public)
      """)
    Task { [weak client] in
      await client?.publish(message)
    }
  }

  /// Register a reload callback for a window. The document view calls
  /// this on appearance and removes it on disappearance.
  func registerReload(
    forWindow windowID: KosmosCore.WindowID,
    handler: @escaping @MainActor () -> Void
  ) {
    reloadHandlers[windowID] = handler
  }

  func unregisterReload(forWindow windowID: KosmosCore.WindowID) {
    reloadHandlers.removeValue(forKey: windowID)
  }

  // MARK: - Bootstrap

  private func bootstrap() async {
    let (client, link) = await makeGalleyKosmosClient(
      role: .visionViewer, deviceID: deviceID)
    self.client = client
    self.link = link
    httpTunnel.attach(client: client)

    startPeerWatch(client: client)
    startSubscriptions(client: client)

    do {
      try await link.start()
      log.notice("Kosmos link started.")
    } catch {
      log.error("""
        Kosmos link failed to start: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  private func startPeerWatch(client: KosmosClient) {
    peerWatchTask = Task { [weak self] in
      for await snapshot in client.peers {
        await MainActor.run {
          self?.peers = snapshot
        }
      }
    }.token
  }

  private func startSubscriptions(client: KosmosClient) {
    openURLSubscription = client
      .subscribe(OpenURL.self) { [weak self] _, message in
        self?.handleOpenURL(message)
      }

    openDocumentSubscription = client
      .subscribe(OpenDocument.self) { [weak self] sender, message in
        self?.handleOpenDocument(message, from: sender)
      }

    contentChangeSubscription = client
      .subscribe(WindowContentChanged.self) { [weak self] sender, message in
        log.notice("""
          ← RECV WindowContentChanged \
          from=\(sender.description, privacy: .public) \
          window=\(message.windowID, privacy: .public)
          """)
        self?.reloadHandlers[message.windowID]?()
      }

    proxyHeadSubscription = client
      .subscribe(ProxyHTTPResponseHead.self) { [weak self] _, head in
        self?.httpTunnel.handle(head)
      }

    proxyChunkSubscription = client
      .subscribe(ProxyHTTPResponseChunk.self) { [weak self] _, chunk in
        self?.httpTunnel.handle(chunk)
      }
  }

  private func handleOpenURL(_ message: OpenURL) {
    log.notice("""
      ← RECV OpenURL window=\(message.windowID, privacy: .public) \
      url=\(message.url.absoluteString, privacy: .public)
      """)
    openWindows[message.windowID] = message.url
    onOpenURL?(message.url)
  }

  private func handleOpenDocument(
    _ message: OpenDocument, from sender: PeerID
  ) {
    log.notice("""
      ← RECV OpenDocument from=\(sender.description, privacy: .public) \
      doc=\(message.docID, privacy: .public) \
      path=\(message.documentPath, privacy: .public) \
      name=\(message.displayName, privacy: .public) \
      scrollLineHint=\(message.scrollLineHint ?? -1, privacy: .public) \
      behavior=\(message.openBehavior.rawValue, privacy: .public)
      """)
    guard let url = KosmosTunnelScheme.previewURL(
      forFile: message.documentPath)
    else {
      log.error("""
        Cannot build galley:// URL for path \
        \(message.documentPath, privacy: .public)
        """)
      return
    }
    openWindows[message.docID] = url
    onOpenURL?(url)
  }
}
#endif
