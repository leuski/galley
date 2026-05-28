import Foundation
import Observation
import OSLog
import GalleyCoreKit
import ALFoundation

private let log = Logger(
  subsystem: bundleIdentifier, category: "PreviewServer")

/// Lifecycle controller for the Galley preview HTTP server. Runs on
/// Hummingbird; binds to `127.0.0.1` on an OS-assigned port. Owners
/// (the Server target's AppModel) observe `stateChanges` and publish
/// the bound port to the shared `net.leuski.galley` defaults so
/// consumers (Quicklook, bundled scripts, future Viewer surface) can
/// discover the endpoint.
///
/// Loopback-only by design. Same-machine consumers (Mac Viewer,
/// Quicklook, browsers, BBEdit) reach the listener via `127.0.0.1`.
/// AVP doesn't dial the HTTP listener directly — it tunnels each
/// request over Kosmos through `Responder`, which proxies
/// to this loopback endpoint on AVP's behalf. No HTTPS, no cert
/// provisioning, no AWDL ingress concerns.
@Observable
@MainActor
public final class PreviewServerController {
  public enum State: Equatable, Sendable {
    case stopped
    case running(url: URL)
    case failed(message: String)
  }

  public private(set) var state: State = .stopped {
    didSet { stateContinuation.yield(state) }
  }

  /// Emits every `state` transition. Use to await a specific
  /// transition (e.g. the first `.running` after a fresh `start()`)
  /// without polling. Single-consumer by design; callers that need
  /// fan-out should layer their own broadcaster on top.
  @ObservationIgnored
  public let stateChanges: AsyncStream<State>
  @ObservationIgnored
  private let stateContinuation: AsyncStream<State>.Continuation

  @ObservationIgnored private var httpTask: Task<Void, Never>?

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

  /// Starts the loopback HTTP listener. AVP traffic doesn't reach the
  /// listener directly — `Responder` proxies Kosmos
  /// `ProxyHTTPRequest` messages through the same endpoint.
  public func start() {
    stop()

    let templateProvider = selectedTemplateProvider
    let renderProvider = rendererProvider
    let watcher = self.watcher

    httpTask = startHTTPListener(
      bindHost: GalleyConstants.defaultHost,
      templateProvider: templateProvider,
      renderProvider: renderProvider,
      watcher: watcher)
  }

  /// Spins up the HTTP listener and returns the task running it.
  private func startHTTPListener(
    bindHost: String,
    templateProvider: @escaping @Sendable () async -> Template,
    renderProvider: @escaping @Sendable () async -> (any MarkdownRenderer)?,
    watcher: DocumentWatcher
  ) -> Task<Void, Never> {
    let boundPort = BoundPort()
    let router = Routes.makeRouter(
      hostURLProvider: {
        await Self.endpointURL(scheme: "http", port: boundPort.load())
      },
      extraAllowedHostsProvider: { [] },
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
          self.publishHTTPBound(endpoint: endpoint)
        }
      })

    return Task { [weak self] in
      do {
        try await app.run()
        // Hummingbird returns normally on cooperative cancel (no
        // CancellationError thrown); detect via Task.isCancelled so
        // `publishStopped()` doesn't overwrite the replacement
        // listener's freshly-published state.
        if Task.isCancelled { return }
      } catch is CancellationError {
        // `start()` called `stop()` which cancelled us in order to
        // hand the slot to a fresh task that has already bound.
        // Bail before publishStopped overwrites that fresh state.
        return
      } catch {
        await self?.publishFailure(error.localizedDescription)
        return
      }
      await self?.publishStopped()
    }
  }

  /// Called from the HTTP listener's `onServerRunning` once the port
  /// is known. Publishes the running URL. The port itself reaches
  /// other processes through the shared `net.leuski.galley` defaults
  /// — owners observe `stateChanges` and write
  /// `Defaults.shared.serverHTTPPort` themselves.
  private func publishHTTPBound(endpoint: URL?) {
    if let endpoint {
      self.state = .running(url: endpoint)
    }
  }

  public func stop() {
    httpTask?.cancel()
    httpTask = nil
    state = .stopped
  }

  nonisolated private func publishStopped() async {
    await MainActor.run {
      self.state = .stopped
    }
  }

  nonisolated private func publishFailure(_ message: String) async {
    await MainActor.run {
      self.state = .failed(message: message)
    }
  }

  public var serverURL: URL? {
    guard case .running(let url) = state else { return nil }
    return url
  }

  /// Returns an `http://127.0.0.1:<port>/` URL when `port` is
  /// non-zero, nil otherwise.
  nonisolated static func endpointURL(scheme: String, port: UInt16) -> URL? {
    guard port != 0 else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = GalleyConstants.defaultHost
    components.port = Int(port)
    return components.url
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
