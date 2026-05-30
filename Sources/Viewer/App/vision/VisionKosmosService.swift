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
  subsystem: bundleIdentifier, category: "VisionKosmosService")

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
final class VisionKosmosService: KosmosService<GalleyKosmosRole> {
  /// AVP-side HTTP tunnel client. Exposed so `WebPage` configuration
  /// can hand it to the `KosmosTunnelSchemeHandler` it installs on
  /// the `galley://` scheme.
  let httpTunnelClient: Client

  @ObservationIgnored private let host = ServiceHost(role: .visionViewer)

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

  func makeLink() async -> KosmosClient {
    await host.makeLink()
  }

  func configure(host: ServiceHost, client: KosmosClient) async {
    httpTunnelClient.attach(client: client)

    host.subscribe(OpenURL.self) { [weak self] _, message in
      self?.handleOpenURL(message)
    }

    host.subscribe(OpenDocument.self) { [weak self] sender, message in
      self?.handleOpenDocument(message, from: sender)
    }

    host.subscribe(WindowContentChanged.self) { [weak self] _, message in
      self?.reloadHandlers[message.windowID]?()
    }

    // Receiver-side tunnel wiring (`ProxyHTTPResponseHead` /
    // `ProxyHTTPResponseChunk` → the in-flight request) is shared in
    // `KosmosHTTPTunnel`.
    httpTunnelClient.install(on: host)
  }

  // Link start/fail logging is handled uniformly by
  // `KosmosServiceHost`; this surface doesn't override `linkDidStart`.

  /// Notify peers that AVP is about to suspend (`scenePhase`
  /// transitioned to `.background` — every scene gone, i.e. real
  /// suspension). The Server folds this into its per-peer resumed flag
  /// and falls back to the local Mac for subsequent opens until
  /// `publishResume` fires. Emission is a generic host capability — any
  /// surface can announce its lifecycle; AVP is just the one that does.
  func publishSuspend() {
    host.publishSuspend()
  }

  /// Notify peers that AVP is serviceable again.
  func publishResume() {
    host.publishResume()
  }

  /// Notify the Mac that the user closed a window on AVP.
  func notifyWindowClosed(_ windowID: KosmosCore.WindowID) {
    openWindows.removeValue(forKey: windowID)
    reloadHandlers.removeValue(forKey: windowID)
    host.publish(CloseWindow(windowID: windowID))
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
    openWindows[message.windowID] = message.url
    onOpenURL?(message.url)
  }

  private func handleOpenDocument(
    _ message: OpenDocument, from sender: PeerID
  ) {
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
