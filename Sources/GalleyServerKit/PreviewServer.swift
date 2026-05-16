import Foundation
import Observation
import Hummingbird
import HummingbirdTLS
import NIOCore
import NIOSSL
import NIOPosix
import GalleyCoreKit

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
/// channel surfaces through `ServerPortFile.endpointURL(for: .https)`.
@Observable
@MainActor
public final class PreviewServerController {
  public enum State: Equatable, Sendable {
    case stopped
    case running(url: URL)
    case failed(message: String)
  }

  public private(set) var state: State = .stopped

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

    let httpBoundPort = BoundPort()
    let httpRouter = Routes.makeRouter(
      hostURLProvider: {
        await Self.endpointURL(scheme: "http", port: httpBoundPort.load())
      },
      selectedTemplateProvider: templateProvider,
      rendererProvider: renderProvider,
      watcher: watcher)

    let httpApp = Application(
      router: httpRouter,
      configuration: .init(
        address: .hostname(GalleyConstants.defaultHost, port: 0),
        serverName: nil),
      onServerRunning: { @Sendable channel in
        guard let portInt = channel.localAddress?.port,
              let port = UInt16(exactly: portInt) else {
          return
        }
        await httpBoundPort.store(port)
        let endpoint = Self.endpointURL(scheme: "http", port: port)
        await MainActor.run {
          do {
            try ServerPortFile.write(port, for: .http)
            if let endpoint { self.state = .running(url: endpoint) }
          } catch {
            self.state = .failed(message: String(
              localized:
                "Cannot write port file: \(error.localizedDescription)",
              bundle: .galleyServerKit))
          }
        }
      })

    httpTask = Task { [weak self] in
      do {
        try await httpApp.run()
      } catch is CancellationError {
        // normal shutdown
      } catch {
        await self?.publishFailure(error.localizedDescription)
      }
      await self?.publishStopped()
    }

    if let tlsConfiguration = Self.tryLoadTLSConfiguration() {
      httpsTask = startTLSListener(
        tlsConfiguration: tlsConfiguration,
        templateProvider: templateProvider,
        renderProvider: renderProvider,
        watcher: watcher)
    }
  }

  /// Spins up the HTTPS listener and returns the task running it.
  /// HTTPS failure is intentionally non-fatal — the HTTP listener
  /// keeps serving and the `.https` port file is cleared so
  /// consumers fall back via `ServerPortFile.preferredEndpointURL`.
  private func startTLSListener(
    tlsConfiguration: TLSConfiguration,
    templateProvider: @escaping @Sendable () async -> Template,
    renderProvider: @escaping @Sendable () async -> (any MarkdownRenderer)?,
    watcher: DocumentWatcher
  ) -> Task<Void, Never>? {
    let boundPort = BoundPort()
    let router = Routes.makeRouter(
      hostURLProvider: {
        await Self.endpointURL(scheme: "https", port: boundPort.load())
      },
      selectedTemplateProvider: templateProvider,
      rendererProvider: renderProvider,
      watcher: watcher)

    let httpsApp: Application<RouterResponder<BasicRequestContext>>
    do {
      httpsApp = Application(
        router: router,
        server: try .tls(.http1(), tlsConfiguration: tlsConfiguration),
        configuration: .init(
          address: .hostname(GalleyConstants.defaultHost, port: 0),
          serverName: nil),
        onServerRunning: { @Sendable channel in
          guard let portInt = channel.localAddress?.port,
                let port = UInt16(exactly: portInt)
          else { return }
          await boundPort.store(port)
          try? ServerPortFile.write(port, for: .https)
        })
    } catch {
      // `.tls(...)` failed (e.g. invalid certificate chain). Continue
      // serving HTTP only; clear any stale .https entry.
      ServerPortFile.clear(for: .https)
      return nil
    }

    return Task {
      do {
        try await httpsApp.run()
      } catch is CancellationError {
        // normal shutdown
      } catch {
        // HTTPS failure is non-fatal for the HTTP listener.
      }
      ServerPortFile.clear(for: .https)
    }
  }

  public func stop() {
    ServerPortFile.clear(for: .http)
    ServerPortFile.clear(for: .https)
    httpTask?.cancel()
    httpsTask?.cancel()
    httpTask = nil
    httpsTask = nil
    state = .stopped
  }

  nonisolated private func publishStopped() async {
    await MainActor.run {
      ServerPortFile.clear(for: .http)
      ServerPortFile.clear(for: .https)
      self.state = .stopped
    }
  }

  nonisolated private func publishFailure(_ message: String) async {
    await MainActor.run {
      ServerPortFile.clear(for: .http)
      ServerPortFile.clear(for: .https)
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
    let certURL = dir.appendingPathComponent("server-cert.pem")
    let keyURL = dir.appendingPathComponent("server-key.pem")
    let files = FileManager.default
    guard files.isReadableFile(atPath: certURL.path),
          files.isReadableFile(atPath: keyURL.path)
    else { return nil }

    do {
      let certs = try NIOSSLCertificate.fromPEMFile(certURL.path)
      let key = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
      return TLSConfiguration.makeServerConfiguration(
        certificateChain: certs.map { .certificate($0) },
        privateKey: .privateKey(key))
    } catch {
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
