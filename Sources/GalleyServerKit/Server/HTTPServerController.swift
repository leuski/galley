import Foundation
import Observation

/// Top-level public state enum shared by the generic
/// `HTTPServerController` and its Galley-specific facade
/// `PreviewServerController`. Hoisted out of the controller because
/// the controller itself is internal (its `start(makeRouter:)` signature
/// would otherwise leak the internal `Router`/`BasicRequestContext`
/// shim types), but the state cases need to be reachable by callers
/// like `Sources/Server/App/AppModel.swift` that pattern-match on them.
public enum HTTPServerState: Equatable, Sendable {
  case stopped
  case running(url: URL)
  case failed(message: String)
}

// Generic HTTP-server lifecycle controller. Knows nothing about Galley
// — it owns the state machine, the AsyncStream<State> observer surface,
// the background Task running FlyingFox's `Application.run()`, and the
// onServerRunning → bound-URL hand-off. Galley-specific wiring
// (template / renderer providers, the document watcher, the route
// catalogue) lives in `PreviewServerController`, which constructs a
// `Router` via `makeRouter` and delegates the lifecycle here.
//
// Internal to the kit on purpose. The kit's public surface is
// `PreviewServerController`; broadening this type's visibility would
// also have to expose the `Router` / `BasicRequestContext` shim types,
// and those are an implementation detail of the FlyingFox adapter.
@Observable
@MainActor
final class HTTPServerController {
  typealias State = HTTPServerState

  private(set) var state: State = .stopped {
    didSet { stateContinuation.yield(state) }
  }

  /// Emits every `state` transition. Use to await a specific
  /// transition (e.g. the first `.running` after a fresh `start()`)
  /// without polling. Single-consumer by design; callers that need
  /// fan-out should layer their own broadcaster on top.
  @ObservationIgnored
  let stateChanges: AsyncStream<State>
  @ObservationIgnored
  private let stateContinuation: AsyncStream<State>.Continuation
  @ObservationIgnored
  private var httpTask: Task<Void, Never>?

  init() {
    let (stream, continuation) = AsyncStream<State>.makeStream()
    self.stateChanges = stream
    self.stateContinuation = continuation
  }

  var serverURL: URL? {
    guard case .running(let url) = state else { return nil }
    return url
  }

  /// Binds a new listener on `bindHost` at an OS-assigned port. Any
  /// prior listener is cancelled first. The `makeRouter` closure is
  /// invoked synchronously *before* the bind so route handlers are
  /// registered against the freshly-created `Router`; the
  /// `boundURL` parameter is a closure that resolves to the
  /// listener's URL once `onServerRunning` has fired (returns nil
  /// before then). This is what lets route handlers compose absolute
  /// URLs without server-side state.
  func start(
    bindHost: String,
    makeRouter: @Sendable (
      _ boundURL: @escaping @Sendable () async -> URL?
    ) -> Router<BasicRequestContext>
  ) {
    stop()
    httpTask = startListener(bindHost: bindHost, makeRouter: makeRouter)
  }

  func stop() {
    httpTask?.cancel()
    httpTask = nil
    state = .stopped
  }

  // MARK: - Internals

  private func startListener(
    bindHost: String,
    makeRouter: @Sendable (
      _ boundURL: @escaping @Sendable () async -> URL?
    ) -> Router<BasicRequestContext>
  ) -> Task<Void, Never> {
    let boundPort = BoundPort()
    let host = bindHost
    let boundURLProvider: @Sendable () async -> URL? = {
      await Self.endpointURL(
        scheme: "http", host: host, port: boundPort.load())
    }
    let router = makeRouter(boundURLProvider)

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
        let endpoint = Self.endpointURL(
          scheme: "http", host: host, port: port)
        await MainActor.run {
          self.publishHTTPBound(endpoint: endpoint)
        }
      })

    return Task { [weak self] in
      do {
        try await app.run()
        // FlyingFox / Hummingbird-style cooperative cancel: the run
        // method returns normally (no CancellationError thrown). Use
        // Task.isCancelled to detect that path so `publishStopped()`
        // doesn't overwrite the replacement listener's state when
        // `start()` was called immediately after.
        if Task.isCancelled { return }
      } catch is CancellationError {
        // `start()` called `stop()` which cancelled us in order to
        // hand the slot to a fresh task that has already bound.
        return
      } catch {
        await self?.publishFailure(error.localizedDescription)
        return
      }
      await self?.publishStopped()
    }
  }

  /// Called from the listener's `onServerRunning` once the port is
  /// known. Publishes the running URL.
  private func publishHTTPBound(endpoint: URL?) {
    if let endpoint {
      self.state = .running(url: endpoint)
    }
  }

  nonisolated private func publishStopped() async {
    await MainActor.run { self.state = .stopped }
  }

  nonisolated private func publishFailure(_ message: String) async {
    await MainActor.run { self.state = .failed(message: message) }
  }

  /// Returns an `http://<host>:<port>/` URL when `port` is non-zero,
  /// nil otherwise. Nonisolated so it can be called from the
  /// background bind callback without hopping back to MainActor.
  nonisolated static func endpointURL(
    scheme: String, host: String, port: UInt16
  ) -> URL? {
    guard port != 0 else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
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
