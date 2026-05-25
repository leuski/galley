#if os(visionOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosHTTPTunnel
import KosmosTransport
import Observation
import OSLog
import SwiftUI

private let log = Logger(
  subsystem: bundleIdentifier, category: "KosmosVisionService")

/// AVP-side Kosmos surface. Advertises as a `visionViewer`, mirrors
/// the discovered peer set, subscribes to bridge messages (open-document,
/// content changes), and publishes lifecycle to the bridge so the Mac
/// can gate AVP reachability on suspend / resume.
///
/// Also owns the AVP end of the HTTP tunnel — every `galley://` URL
/// the WebView fetches becomes a `ProxyHTTPRequest` Kosmos broadcast,
/// and the response chunks are routed back through
/// `Client`. The service is the single subscription point
/// for the two response message types so we don't spin up a per-request
/// subscription.
///
/// Conforms to `KosmosService`; the `KosmosServiceHost` owns the
/// bootstrap / peer-watch / stop boilerplate and calls back through
/// the protocol.
@MainActor
@Observable
final class KosmosVisionService: KosmosService {
  /// AVP-side HTTP tunnel client. Exposed so `WebPage` configuration
  /// can hand it to the `KosmosTunnelSchemeHandler` it installs on
  /// the `galley://` scheme.
  let httpTunnelClient: Client

  @ObservationIgnored private let host = KosmosServiceHost(role: .visionViewer)

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
    self.httpTunnelClient = Client(client: nil)
  }

  /// Begin advertising and browsing. Idempotent.
  func start() {
    host.start(service: self)
  }

  func stop() async {
    httpTunnelClient.stopAll()
    reloadHandlers.removeAll()
    openWindows.removeAll()
    await host.stop()
  }

  // MARK: - KosmosService

  func makeLink() async -> (KosmosClient, any KosmosLink) {
    await host.makeLink(role: .visionViewer)
  }

  func configure(host: KosmosServiceHost, client: KosmosClient) async {
    httpTunnelClient.attach(client: client)

    host.subscribe(OpenURL.self) { [weak self] _, message in
      self?.handleOpenURL(message)
    }

    host.subscribe(OpenDocument.self) { [weak self] sender, message in
      self?.handleOpenDocument(message, from: sender)
    }

    host.subscribe(WindowContentChanged.self) { [weak self] sender, message in
      log.notice("""
        ← RECV WindowContentChanged \
        from=\(sender.description, privacy: .public) \
        window=\(message.windowID, privacy: .public)
        """)
      self?.reloadHandlers[message.windowID]?()
    }

    host.subscribe(ProxyHTTPResponseHead.self) { [weak self] _, head in
      self?.httpTunnelClient.handle(head)
    }

    host.subscribe(ProxyHTTPResponseChunk.self) { [weak self] _, chunk in
      self?.httpTunnelClient.handle(chunk)
    }
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

  /// Notify the Mac that AVP is about to suspend (`scenePhase`
  /// transitioned to `.background` — typically the user closed the
  /// last AVP Galley window including the anchor). Mac side flips the
  /// per-peer resumed flag and falls back to local Galley.app for
  /// subsequent opens until `publishResume` fires.
  func publishSuspend() {
    let message = AppWillSuspend(
      appID: Self.galleyAppID,
      deviceID: host.deviceID)
    log.notice("→ PUBLISH AppWillSuspend")
    if let client = host.client {
      Task { [client] in await client.publish(message) }
    }
  }

  /// Notify the Mac that AVP is serviceable again.
  func publishResume() {
    let message = AppDidResume(
      appID: Self.galleyAppID,
      deviceID: host.deviceID)
    log.notice("→ PUBLISH AppDidResume")
    if let client = host.client {
      Task { [client] in await client.publish(message) }
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
    if let client = host.client {
      Task { [client] in await client.publish(message) }
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

  // MARK: - Inbound handling

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
    guard let url = TunnelScheme.originURL.galleyPreviewURL(
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
