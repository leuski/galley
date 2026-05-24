import Foundation
import Observation
import Hummingbird
import HummingbirdTLS
import NIOCore
import NIOSSL
import NIOPosix
import os
import GalleyCoreKit
import ALFoundation

private let log = Logger(
  subsystem: bundleIdentifier, category: "PreviewServer")

/// Lifecycle controller for the Galley preview HTTP server. Runs on
/// Hummingbird; binds to `127.0.0.1` on an OS-assigned port and writes
/// the bound port to `ServerPortFile` so consumers (Viewer probe,
/// Quicklook, bundled scripts) can discover the endpoint.
///
/// If `server-cert.pem` and `server-key.pem` are present in
/// `GalleyConstants.applicationSupportDirectory`, a parallel HTTPS
/// listener is started on a separate OS-assigned port and its port
/// written to `ServerPortFile` under `.https`. Consumers that prefer
/// HTTPS (via `ServerPortFile.preferredEndpointURL`) pick it up
/// automatically.
///
/// `state.running(url:)` always reports the HTTP URL; the HTTPS
/// channel surfaces through `ServerPortFile.https.endpointURL`.
@Observable
@MainActor
public final class PreviewServerController {
  public enum State: Equatable, Sendable {
    case stopped
    case running(url: URL)
    case failed(message: String)
  }

  /// Network surface the listener exposes.
  /// - `.loopback`: bind `127.0.0.1`; only loopback Host headers are
  ///   accepted. Default; matches the long-standing behavior.
  /// - `.lanReachable`: bind dual-stack `::` (accepts both IPv4 and
  ///   IPv6 — most macOS-relevant peers reach us via IPv6, including
  ///   AVP over AWDL and any global-IPv6 path when IPv4 collides on
  ///   iPhone-hotspot CGNAT); `extraAllowedHostnames` widens the
  ///   Host-header allowlist (e.g., LAN IP literals) so a paired
  ///   Kosmos peer can reach the server.
  public enum BindMode: Equatable, Sendable {
    case loopback
    case lanReachable(extraAllowedHostnames: Set<String>)

    var hostString: String {
      switch self {
        // `::` enables IPV6_V6ONLY=false on Apple platforms (NIO default
        // for IPv6 bootstrap on Darwin), so a single listener handles
        // both IPv4 and IPv6 traffic. Binding `0.0.0.0` would miss IPv6
        // and break peers reaching us via a global / link-local v6.
      case .loopback: return GalleyConstants.defaultHost
      case .lanReachable: return "::"
      }
    }

    var extraAllowedHostnames: Set<String> {
      switch self {
      case .loopback: return []
      case .lanReachable(let names): return names
      }
    }
  }

  public private(set) var state: State = .stopped {
    didSet { stateContinuation.yield(state) }
  }
  public private(set) var bindMode: BindMode = .loopback

  /// Emits every `state` transition. Use to await a specific
  /// transition (e.g. the first `.running` after a fresh `start()`)
  /// without polling. Single-consumer by design; callers that need
  /// fan-out should layer their own broadcaster on top.
  @ObservationIgnored
  public let stateChanges: AsyncStream<State>
  @ObservationIgnored
  private let stateContinuation: AsyncStream<State>.Continuation

  @ObservationIgnored private var httpTask: Task<Void, Never>?
  @ObservationIgnored private var httpsTask: Task<Void, Never>?

  @ObservationIgnored public let watcher = DocumentWatcher()

  @ObservationIgnored private let selectedTemplateProvider: @Sendable ()
  async -> Template
  @ObservationIgnored private let rendererProvider: @Sendable ()
  async -> (any MarkdownRenderer)?

  public init(
    selectedTemplateProvider: @escaping @Sendable () async -> Template,
    rendererProvider: @escaping @Sendable () async -> (any MarkdownRenderer)?
  ) {
    self.selectedTemplateProvider = selectedTemplateProvider
    self.rendererProvider = rendererProvider
    let (stream, continuation) = AsyncStream<State>.makeStream()
    self.stateChanges = stream
    self.stateContinuation = continuation
  }

  /// Switch the listener between loopback-only and LAN-reachable modes.
  /// Stops the current listener (cancelling in-flight requests),
  /// records the new mode, and starts a fresh listener with the
  /// matching bind host + Host-header allowlist. No-op if the mode is
  /// already current.
  public func setBindMode(_ newMode: BindMode) {
    guard newMode != bindMode else { return }
    bindMode = newMode
    if state != .stopped {
      start()
    }
  }

  /// Starts the HTTP listener (always) and, if cert + key PEM files
  /// exist in Application Support, an HTTPS listener alongside it.
  /// Both listeners share the same routes; each one reports its
  /// own bound port through `ServerPortFile`.
  public func start() {
    stop()

    let templateProvider = selectedTemplateProvider
    let renderProvider = rendererProvider
    let watcher = self.watcher
    let extraHosts = bindMode.extraAllowedHostnames

    // HTTP serves only the same-machine same-user trust domain — the
    // Mac Viewer's loopback render path. We pin it to 127.0.0.1
    // regardless of bindMode so it's never reachable over LAN, even
    // when HTTPS flips to dual-stack `::` for an AVP peer.
    httpTask = startHTTPListener(
      bindHost: GalleyConstants.defaultHost,
      extraHosts: extraHosts,
      templateProvider: templateProvider,
      renderProvider: renderProvider,
      watcher: watcher)

    if let tlsConfiguration = Self.tryLoadTLSConfiguration() {
      httpsTask = startTLSListener(
        tlsConfiguration: tlsConfiguration,
        bindHost: bindMode.hostString,
        extraHosts: extraHosts,
        templateProvider: templateProvider,
        renderProvider: renderProvider,
        watcher: watcher)
    }
  }

  /// Spins up the HTTP listener and returns the task running it.
  /// Mirrors `startTLSListener` so both listeners follow the same
  /// build-router → build-app → spawn-task shape.
  private func startHTTPListener(
    bindHost: String,
    extraHosts: Set<String>,
    templateProvider: @escaping @Sendable () async -> Template,
    renderProvider: @escaping @Sendable () async -> (any MarkdownRenderer)?,
    watcher: DocumentWatcher
  ) -> Task<Void, Never> {
    let boundPort = BoundPort()
    let router = Routes.makeRouter(
      hostURLProvider: {
        await Self.endpointURL(scheme: "http", port: boundPort.load())
      },
      extraAllowedHostsProvider: { extraHosts },
      selectedTemplateProvider: templateProvider,
      rendererProvider: renderProvider,
      watcher: watcher)

    let app = Application(
      router: router,
      configuration: .init(
        address: .hostname(bindHost, port: 0),
        serverName: nil),
      onServerRunning: { @Sendable channel in
        guard let portInt = channel.localAddress?.port,
              let port = UInt16(exactly: portInt) else {
          return
        }
        await boundPort.store(port)
        let endpoint = Self.endpointURL(scheme: "http", port: port)
        await MainActor.run {
          self.publishHTTPBound(port: port, endpoint: endpoint)
        }
      })

    return Task { [weak self] in
      do {
        try await app.run()
        // Hummingbird returns normally on cooperative cancel (no
        // CancellationError thrown); detect via Task.isCancelled so
        // `publishStopped()` doesn't wipe the replacement listener's
        // freshly-written port files.
        if Task.isCancelled { return }
      } catch is CancellationError {
        // `start()` called `stop()` which cancelled us in order to
        // hand the slot to a fresh task that has already bound and
        // written its own port file. Bail out before publishStopped
        // wipes that fresh state.
        return
      } catch {
        await self?.publishFailure(error.localizedDescription)
        return
      }
      await self?.publishStopped()
    }
  }

  /// Called from the HTTP listener's `onServerRunning` once the port
  /// is known. Writes the `.http` port file (locked — it doubles as
  /// the single-instance sentinel) and publishes the running URL, or
  /// tears the listener down with a localized failure message.
  private func publishHTTPBound(port: UInt16, endpoint: URL?) {
    do {
      // Locked write: the `.http` port file doubles as the
      // single-instance sentinel. If another Galley Server is
      // already running on this user account, this throws
      // `LockedByAnotherProcess` and we tear down the listener
      // we just bound — ServerApp's NSRunningApplication guard
      // catches most duplicates, this catches the rest.
      try ServerPortFile.http.write(port, lock: true)
      if let endpoint { self.state = .running(url: endpoint) }
    } catch is ServerPortFile.LockedByAnotherProcess {
      // Tear down the listener we just bound, then publish
      // the failure. `stop()` resets state to `.stopped`, so
      // the failed-state assignment has to come after it.
      self.stop()
      self.state = .failed(message: String(
        localized: """
          Another Galley Server is already running on this user account.
          """,
        bundle: .galleyServerKit))
    } catch {
      self.stop()
      self.state = .failed(message: String(
        localized:
          "Cannot write port file: \(error.localizedDescription)",
        bundle: .galleyServerKit))
    }
  }

  /// Spins up the HTTPS listener and returns the task running it.
  /// HTTPS failure is intentionally non-fatal — the HTTP listener
  /// keeps serving and the `.https` port file is cleared so
  /// consumers fall back via `ServerPortFile.preferredEndpointURL`.
  ///
  /// Cancellation: `start()` cancels the previous task before spawning
  /// a fresh one. Hummingbird is built on swift-service-lifecycle,
  /// which handles cooperative cancellation by *returning normally*
  /// from `app.run()` rather than throwing `CancellationError`. The
  /// fall-through clear is gated on `Task.isCancelled` so we don't
  /// race the replacement listener's freshly-written port file.
  private func startTLSListener(
    tlsConfiguration: TLSConfiguration,
    bindHost: String,
    extraHosts: Set<String>,
    templateProvider: @escaping @Sendable () async -> Template,
    renderProvider: @escaping @Sendable () async -> (any MarkdownRenderer)?,
    watcher: DocumentWatcher
  ) -> Task<Void, Never>? {
    let boundPort = BoundPort()
    let router = Routes.makeRouter(
      hostURLProvider: {
        await Self.endpointURL(scheme: "https", port: boundPort.load())
      },
      extraAllowedHostsProvider: { extraHosts },
      selectedTemplateProvider: templateProvider,
      rendererProvider: renderProvider,
      watcher: watcher)
    let httpsApp: Application<RouterResponder<BasicRequestContext>>
    do {
      httpsApp = Application(
        router: router,
        server: try .tls(.http1(), tlsConfiguration: tlsConfiguration),
        configuration: .init(
          address: .hostname(bindHost, port: 0),
          serverName: nil),
        onServerRunning: { @Sendable channel in
          guard let portInt = channel.localAddress?.port,
                let port = UInt16(exactly: portInt)
          else {
            let addrStr = String(describing: channel.localAddress)
            log.error("""
              HTTPS onServerRunning: channel has no usable local port \
              (localAddress=\(addrStr, privacy: .public))
              """)
            return
          }
          await boundPort.store(port)
          try? ServerPortFile.https.write(port)
        })
    } catch {
      log.error("""
        HTTPS listener configuration failed; HTTP-only: \
        \(error.localizedDescription, privacy: .public)
        """)
      ServerPortFile.https.clear()
      return nil
    }

    return Task {
      do {
        try await httpsApp.run()
        // Hummingbird returns normally on cooperative cancel (no
        // CancellationError thrown). Detect via Task.isCancelled so
        // the fall-through clear doesn't wipe the replacement
        // listener's freshly-written port file.
        if Task.isCancelled { return }
        log.error("""
          HTTPS listener exited normally without cancellation. \
          Hummingbird's app.run() should run forever; a normal return \
          here means the listener stopped serving and the port file \
          will be cleared.
          """)
      } catch is CancellationError {
        return
      } catch {
        log.error("""
          HTTPS listener exited with error: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
      ServerPortFile.https.clear()
    }
  }

  public func stop() {
    ServerPortFile.http.clear()
    ServerPortFile.https.clear()
    httpTask?.cancel()
    httpsTask?.cancel()
    httpTask = nil
    httpsTask = nil
    state = .stopped
  }

  nonisolated private func publishStopped() async {
    await MainActor.run {
      ServerPortFile.http.clear()
      ServerPortFile.https.clear()
      self.state = .stopped
    }
  }

  nonisolated private func publishFailure(_ message: String) async {
    await MainActor.run {
      ServerPortFile.http.clear()
      ServerPortFile.https.clear()
      self.state = .failed(message: message)
    }
  }

  public var serverURL: URL? {
    guard case .running(let url) = state else { return nil }
    return url
  }

  /// Returns an `http(s)://127.0.0.1:<port>/` URL when `port` is
  /// non-zero, nil otherwise.
  nonisolated static func endpointURL(scheme: String, port: UInt16) -> URL? {
    guard port != 0 else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = GalleyConstants.defaultHost
    components.port = Int(port)
    return components.url
  }

  /// Loads `server-cert.pem` + `server-key.pem` from
  /// `GalleyConstants.applicationSupportDirectory` and produces a
  /// server `TLSConfiguration`. Returns nil if either file is missing
  /// or unreadable; returns nil (rather than throwing) if parsing
  /// fails, so a bad cert disables HTTPS without crashing the app.
  private static func tryLoadTLSConfiguration() -> TLSConfiguration? {
    let dir = GalleyConstants.applicationSupportDirectory
    let certURL = dir / GalleyConstants.serverCertificateFilename
    let keyURL = dir / GalleyConstants.serverPrivateKeyFilename

    do {
      let certs = try NIOSSLCertificate.fromPEMFile(certURL.path)
      let key = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
      return TLSConfiguration.makeServerConfiguration(
        certificateChain: certs.map { .certificate($0) },
        privateKey: .privateKey(key))
    } catch {
      log.error("""
        TLS configuration load failed (HTTPS disabled): \
        \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }
}

/// Thread-safe holder for the bound port of one listener. The bound
/// port is unknown until `onServerRunning` fires, but the router
/// closures (which need to build the host URL) are created earlier.
/// An actor lets the closures `await` the value without leaking
/// non-Sendable state.
private actor BoundPort {
  private var port: UInt16 = 0
  func load() -> UInt16 { port }
  func store(_ value: UInt16) { port = value }
}

public extension GalleyConstants {
  static let serverCertificateFilename = "server-cert.pem"
  static let serverPrivateKeyFilename = "server-key.pem"
}
