#if os(visionOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosTransport
import KosmosWebView
import Observation
import OSLog
import SwiftUI

private let log = Logger(
  subsystem: bundleIdentifier, category: "KosmosVisionService")

/// AVP-side Kosmos surface. Owns a single `KosmosTransport.KosmosClient`
/// advertising as a `visionViewer`, mirrors the discovered peer set,
/// subscribes to bridge messages (cert pin, open-document, content
/// changes), and publishes lifecycle to the bridge so the Mac can
/// gate AVP reachability on suspend / resume.
@MainActor
@Observable
final class KosmosVisionService {
  /// Latest received bridge advertisement. Kept across reconnects so
  /// cold-launches can pin-validate scene-restored URLs before the
  /// next advertisement arrives.
  private(set) var pinnedCertSHA256: Data?

  /// Snapshot of peers visible to Kosmos. Other code (settings,
  /// debugging) can observe this; the service itself doesn't branch
  /// on it beyond surfacing the latest bridge.
  private(set) var peers: [PeerID: PeerInfo] = [:]

  @ObservationIgnored private let deviceID: UUID
  @ObservationIgnored private var client: KosmosClient?
  @ObservationIgnored private var link: LoomKosmosLink?

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var peerWatchTask: Task<Void, Never>?
  @ObservationIgnored private var bridgeAdSubscription: Task<Void, Never>?
  @ObservationIgnored private var openURLSubscription: Task<Void, Never>?
  @ObservationIgnored private var openDocumentSubscription: Task<Void, Never>?
  @ObservationIgnored private var contentChangeSubscription: Task<Void, Never>?

  /// Handler for incoming `OpenURL` messages — wired by the app to
  /// call `openWindow(value: url)`. The service holds the closure
  /// rather than owning a SwiftUI environment value because
  /// `openWindow` is only available inside view bodies.
  @ObservationIgnored var onOpenURL: (@MainActor (URL) -> Void)?

  /// Per-window reload handlers. The document view registers on
  /// appearance, unregisters on disappearance.
  @ObservationIgnored
  private var reloadHandlers: [KosmosCore.WindowID: @MainActor () -> Void] = [:]
  @ObservationIgnored
  private var openWindows: [KosmosCore.WindowID: URL] = [:]

  init() {
    self.deviceID = loadOrMakeGalleyDeviceID(role: .visionViewer)
  }

  /// Begin advertising and browsing. Idempotent.
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
    bridgeAdSubscription?.cancel()
    bridgeAdSubscription = nil
    openURLSubscription?.cancel()
    openURLSubscription = nil
    openDocumentSubscription?.cancel()
    openDocumentSubscription = nil
    contentChangeSubscription?.cancel()
    contentChangeSubscription = nil
    if let client {
      await client.stop()
    }
    client = nil
    link = nil
    reloadHandlers.removeAll()
    openWindows.removeAll()
    KosmosPinnedCertSource.update(nil)
    pinnedCertSHA256 = nil
    peers = [:]
  }

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
    }
  }

  private func startSubscriptions(client: KosmosClient) {
    bridgeAdSubscription = Task { [weak self] in
      let stream = client.subscribe(BridgeAdvertisement.self)
      for await (sender, advertisement) in stream {
        await MainActor.run {
          self?.handleBridgeAdvertisement(advertisement, from: sender)
        }
      }
    }

    openURLSubscription = Task { [weak self] in
      let stream = client.subscribe(OpenURL.self)
      for await (_, message) in stream {
        await MainActor.run {
          self?.handleOpenURL(message)
        }
      }
    }

    openDocumentSubscription = Task { [weak self] in
      let stream = client.subscribe(OpenDocument.self)
      for await (sender, message) in stream {
        await MainActor.run {
          self?.handleOpenDocument(message, from: sender)
        }
      }
    }

    contentChangeSubscription = Task { [weak self] in
      let stream = client.subscribe(WindowContentChanged.self)
      for await (sender, message) in stream {
        log.notice("""
          ← RECV WindowContentChanged \
          from=\(sender.description, privacy: .public) \
          window=\(message.windowID, privacy: .public)
          """)
        await MainActor.run {
          self?.reloadHandlers[message.windowID]?()
        }
      }
    }
  }

  private func handleBridgeAdvertisement(
    _ advertisement: BridgeAdvertisement, from sender: PeerID
  ) {
    KosmosPinnedCertSource.update(advertisement.certificateSHA256)
    pinnedCertSHA256 = advertisement.certificateSHA256
    let pinHex = advertisement.certificateSHA256.map {
      String(format: "%02x", $0)
    }.joined()
    log.notice("""
      ← RECV BridgeAdvertisement \
      from=\(sender.description, privacy: .public) \
      base=\(advertisement.baseURL.absoluteString, privacy: .public) \
      certSHA256=\(pinHex, privacy: .public)
      """)
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
    let pinHex = message.certificateSHA256.map {
      String(format: "%02x", $0)
    }.joined()
    log.notice("""
      ← RECV OpenDocument from=\(sender.description, privacy: .public) \
      doc=\(message.docID, privacy: .public) \
      url=\(message.httpsURL.absoluteString, privacy: .public) \
      name=\(message.displayName, privacy: .public) \
      certSHA256=\(pinHex, privacy: .public) \
      scrollLineHint=\(message.scrollLineHint ?? -1, privacy: .public) \
      behavior=\(message.openBehavior.rawValue, privacy: .public)
      """)
    // Apply the cert pin BEFORE we hand the URL to SwiftUI's
    // openWindow. WebKit will fire an auth challenge during the
    // navigation, and `KosmosCertPinner` reads
    // `KosmosPinnedCertSource.current` at challenge time — racing a
    // separate `BridgeAdvertisement` message lost the cert in
    // practice when the AVP-side subscription registration hadn't
    // completed yet. Shipping the cert with the URL closes that race.
    KosmosPinnedCertSource.update(message.certificateSHA256)
    pinnedCertSHA256 = message.certificateSHA256
    openWindows[message.docID] = message.httpsURL
    onOpenURL?(message.httpsURL)
  }
}
#endif
