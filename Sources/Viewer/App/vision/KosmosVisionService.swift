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
/// subscribes to bridge messages (open-document, content changes), and
/// publishes lifecycle to the bridge so the Mac can gate AVP
/// reachability on suspend / resume.
@MainActor
@Observable
final class KosmosVisionService {
  /// Snapshot of peers visible to Kosmos. Other code (settings,
  /// debugging) can observe this; the service itself doesn't branch
  /// on it.
  private(set) var peers: [PeerID: PeerInfo] = [:]

  @ObservationIgnored private let deviceID: UUID
  @ObservationIgnored private var client: KosmosClient?
  @ObservationIgnored private var link: LoomKosmosLink?

  /// Loopback HTTP proxy that fronts the Mac Server. We rewrite the
  /// `httpsURL` in each `OpenDocument` into
  /// `http://127.0.0.1:<proxyPort>/...` before handing it to SwiftUI —
  /// WebKit on visionOS rejects URLs whose host carries an IPv6 zone
  /// identifier. The proxy terminates the TLS to the upstream and
  /// applies the Kosmos cert pin.
  @ObservationIgnored private let proxy = AVPHTTPProxy()

  @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
  @ObservationIgnored private var peerWatchTask: Task<Void, Never>?
  @ObservationIgnored private var openURLSubscription: Task<Void, Never>?
  @ObservationIgnored private var openDocumentSubscription: Task<Void, Never>?
  @ObservationIgnored private var contentChangeSubscription: Task<Void, Never>?

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
  }

  /// Begin advertising and browsing. Idempotent.
  func start() {
    guard bootstrapTask == nil else { return }
    proxy.start()
    bootstrapTask = Task { [weak self] in
      await self?.bootstrap()
    }
  }

  func stop() async {
    bootstrapTask?.cancel()
    bootstrapTask = nil
    peerWatchTask?.cancel()
    peerWatchTask = nil
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
    peers = [:]
    proxy.stop()
  }

  /// Notify the Mac that AVP is about to suspend (`scenePhase`
  /// transitioned to `.background` — typically the user closed all
  /// AVP Galley windows, or took the headset off). Mac side flips the
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
    let candidates = message.hostCandidates.joined(separator: ",")
    log.notice("""
      ← RECV OpenDocument from=\(sender.description, privacy: .public) \
      doc=\(message.docID, privacy: .public) \
      url=\(message.httpsURL.absoluteString, privacy: .public) \
      name=\(message.displayName, privacy: .public) \
      certSHA256=\(pinHex, privacy: .public) \
      hostCandidates=\(candidates, privacy: .public) \
      scrollLineHint=\(message.scrollLineHint ?? -1, privacy: .public) \
      behavior=\(message.openBehavior.rawValue, privacy: .public)
      """)
    // Apply the cert pin BEFORE we hand the URL to SwiftUI's
    // openWindow. `KosmosPinnedCertSource` is read by the in-process
    // `AVPHTTPProxy`'s TLS verify block (and historically by
    // `KosmosCertPinner` for the WebView's direct TLS challenge, now
    // inert on visionOS — WebKit only ever sees loopback HTTP).
    KosmosPinnedCertSource.update(message.certificateSHA256)
    let host = Self.pickUpstreamHost(
      preferred: message.httpsURL.host(percentEncoded: false),
      candidates: message.hostCandidates)
    guard let host else {
      log.error("""
        No dialable host in OpenDocument for \
        \(message.httpsURL.absoluteString, privacy: .public)
        """)
      return
    }
    configureProxy(
      host: host,
      portFrom: message.httpsURL,
      certSHA256: message.certificateSHA256)
    Task { [weak self] in
      guard let self else { return }
      guard let routed = await self.proxy
        .awaitRewrittenURL(for: message.httpsURL)
      else {
        log.error("""
          Proxy never became ready; dropping OpenDocument for \
          \(message.httpsURL.absoluteString, privacy: .public)
          """)
        return
      }
      self.openWindows[message.docID] = routed
      self.onOpenURL?(routed)
    }
  }

  /// Pure host-selection policy. Receivers pick a host they can
  /// actually dial.
  ///
  /// Strategy on both real AVP and the visionOS simulator: prefer
  /// the first non-AWDL candidate (Bonjour, global IPv6, ULA, LAN
  /// IPv4) — these route through interfaces the Mac's HTTPS listener
  /// actually accepts ingress on. AWDL-zoned IPv6 (`fe80::…%awdl0`)
  /// is treated as last-resort because:
  ///
  /// - Simulator: no AWDL interface at all — dials route via `lo0`
  ///   and time out.
  /// - Real AVP: empirically, dials to the Mac's AWDL-zoned host
  ///   get TCP `RST`. Hummingbird's listener doesn't enable
  ///   `NWParameters.includePeerToPeer`, so the kernel refuses
  ///   AWDL ingress even though the listener is bound to `::`.
  ///
  /// `preferred` (the Mac's pick on the `OpenDocument.httpsURL`) is
  /// ignored when AWDL-zoned, since the Mac biases that toward AWDL
  /// for the AWDL-only scenario which we no longer support without
  /// a peer-to-peer listener.
  ///
  /// Returns nil only when every candidate is AWDL-zoned (would
  /// mean the Mac has no Bonjour, global IPv6, ULA, or LAN IPv4
  /// host — degenerate).
  nonisolated static func pickUpstreamHost(
    preferred: String?,
    candidates: [String]
  ) -> String? {
    if let preferred, !BridgeURLBuilder.isAWDLZonedHost(preferred) {
      return preferred
    }
    if let nonAWDL = candidates.first(
      where: { !BridgeURLBuilder.isAWDLZonedHost($0) })
    {
      return nonAWDL
    }
    // Last resort: every candidate is AWDL. Hand back the original
    // preferred (or first candidate) so the caller still has an
    // address to attempt; the dial will likely fail but we don't
    // silently drop the open.
    return preferred ?? candidates.first
  }

  /// Set the proxy's upstream from `(host, port-from-URL, cert)`. The
  /// host is decided by `pickUpstreamHost`; the port comes from the
  /// `OpenDocument` URL, which is authoritatively HTTPS.
  private func configureProxy(
    host: String, portFrom url: URL, certSHA256: Data
  ) {
    guard
      let port = url.port,
      let upstreamPort = UInt16(exactly: port)
    else {
      log.error("""
        Cannot extract port from URL: \
        \(url.absoluteString, privacy: .public)
        """)
      return
    }
    proxy.setUpstream(
      host: host, port: upstreamPort, certSHA256: certSHA256)
  }
}
#endif
