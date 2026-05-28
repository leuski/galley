import Foundation
import HTTPTypes
import FlyingFox
import FlyingSocks

// Hummingbird-shaped HTTP `Application` backed by FlyingFox. Exposes the
// surface `PreviewServerController.startHTTPListener` reaches for:
//
//   Application(
//     router: router,
//     configuration: .init(address: .hostname(host, port: 0),
//                          serverName: nil),
//     onServerRunning: { channel in ... channel.localAddress?.port ... })
//   try await app.run()
//
// `app.run()` returns when the server stops (graceful) or when the
// enclosing Task is cancelled. The bound port is observed asynchronously
// — once `listeningAddress` resolves, `onServerRunning` is fired exactly
// once with a `ServerChannel` whose `localAddress?.port` mirrors NIO's
// channel-bound-address shape.

struct Application: Sendable {
  /// `Configuration` mirrors Hummingbird's nested name so call sites use
  /// `.init(address: .hostname(host, port: p), serverName: nil)` verbatim.
  struct Configuration: Sendable {
    enum BindAddress: Sendable {
      case hostname(String, port: Int)
    }

    let address: BindAddress
    let serverName: String?

    init(address: BindAddress, serverName: String?) {
      self.address = address
      self.serverName = serverName
    }
  }

  let router: Router<BasicRequestContext>
  let configuration: Configuration
  let onServerRunning: @Sendable (ServerChannel) async -> Void

  init(
    router: Router<BasicRequestContext>,
    configuration: Configuration,
    onServerRunning: @escaping @Sendable (ServerChannel) async -> Void
      = { _ in }
  ) {
    self.router = router
    self.configuration = configuration
    self.onServerRunning = onServerRunning
  }

  func run() async throws {
    let host: String
    let port: UInt16
    switch configuration.address {
    case .hostname(let hostname, let portInt):
      host = hostname
      // Configuration's port is Int (Hummingbird shape); narrowing to
      // UInt16 cannot fail for the kit's call sites (it only ever passes
      // 0 for "OS-assigned"), but be defensive in case future callers
      // hand us a wider value.
      guard let narrowed = UInt16(exactly: portInt) else {
        throw ApplicationError.invalidPort(portInt)
      }
      port = narrowed
    }

    let address = try sockaddr_in.inet(ip4: host, port: port)
    let server = HTTPServer(address: address)
    let router = self.router

    // FlyingFox's `*` matches a single path segment; we register one
    // catch-all and dispatch internally via our own `PathPattern` so the
    // kit's existing `/preview/**`, `/template/**`, `/events/**`
    // semantics survive the transport swap. Non-GET methods are not
    // registered → FlyingFox synthesizes a 404, matching the prior
    // Hummingbird behavior where only GET was registered.
    await server.appendRoute("GET /*") { ffRequest in
      await Self.dispatch(ffRequest, through: router)
    }

    // Two child tasks — one runs the server until cancellation or
    // failure; the other waits for `listeningAddress` to surface and
    // fires `onServerRunning` exactly once. When the server task
    // completes (either path), we cancel the watcher so it doesn't
    // outlive the listener.
    try await withThrowingTaskGroup(of: TaskOutcome.self) { group in
      group.addTask {
        do {
          try await server.run()
          return .serverFinished(nil)
        } catch {
          return .serverFinished(error)
        }
      }
      group.addTask {
        await Self.publishBoundPort(
          on: server, callback: onServerRunning)
        return .watcherDone
      }
      // First non-watcher outcome is the one we propagate. The watcher
      // may finish first (server bound quickly) — keep waiting for the
      // server task in that case.
      while let outcome = try await group.next() {
        switch outcome {
        case .watcherDone:
          continue
        case .serverFinished(let error):
          group.cancelAll()
          if let error { throw error }
          return
        }
      }
    }
  }

  private enum TaskOutcome: Sendable {
    case watcherDone
    case serverFinished(Error?)
  }

  /// Polls `listeningAddress` until the server has bound, then fires
  /// `onServerRunning` once with a Hummingbird-shaped channel value.
  /// Cooperative cancellation ends the poll quietly if the run task
  /// errors out before the bind completes.
  private static func publishBoundPort(
    on server: HTTPServer,
    callback: @Sendable (ServerChannel) async -> Void
  ) async {
    // Typical bind on loopback is well under 50ms; 5ms × 400 = 2s gives
    // headroom for slow CI without spinning forever on an unfixable
    // bind failure (the server task will have already failed by then
    // and the surrounding group cancels us).
    for _ in 0..<400 {
      if Task.isCancelled { return }
      if let address = await server.listeningAddress {
        let channel = ServerChannel(
          localAddress: ServerAddress(port: port(from: address)))
        await callback(channel)
        return
      }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private static func port(from address: Socket.Address) -> Int? {
    switch address {
    case .ip4(_, let port): return Int(port)
    case .ip6(_, let port): return Int(port)
    case .unix: return nil
    }
  }

  // MARK: - Dispatch

  private static func dispatch(
    _ ffRequest: FlyingFox.HTTPRequest,
    through router: Router<BasicRequestContext>
  ) async -> FlyingFox.HTTPResponse {
    let request = Request(
      uri: Request.URI(path: ffRequest.path),
      head: Request.Head(authority: ffRequest.headers[HTTPHeader.host]),
      headers: toHTTPFields(ffRequest.headers))

    guard let route = router.route(forGetPath: ffRequest.path) else {
      return FlyingFox.HTTPResponse(statusCode: .notFound)
    }

    let response: Response
    do {
      response = try await route.handler(request, BasicRequestContext())
    } catch {
      // Handler-level errors are surfaced as 500. The kit's routes
      // catch their own errors and emit `HTTPResponses.errorPage` —
      // this fallback only triggers if a future handler forgets to.
      return FlyingFox.HTTPResponse(
        statusCode: .internalServerError,
        headers: [HTTPHeader.contentType: "text/plain; charset=utf-8"],
        body: Data("Internal server error\n".utf8))
    }

    return await build(from: response)
  }

  private static func build(
    from response: Response
  ) async -> FlyingFox.HTTPResponse {
    let status = flyingFoxStatus(from: response.status)
    let headers = toFlyingFoxHeaders(response.headers)

    switch response.body.payload {
    case .empty:
      return FlyingFox.HTTPResponse(
        statusCode: status,
        headers: headers,
        body: Data())
    case .buffer(let buffer):
      return FlyingFox.HTTPResponse(
        statusCode: status,
        headers: headers,
        body: buffer.data)
    case .stream(let producer):
      let sequence = makeStreamingBody(producer: producer)
      return FlyingFox.HTTPResponse(
        statusCode: status,
        headers: headers,
        body: sequence)
    }
  }

  /// Spins up the producer task, returns a chunked-transfer body
  /// sequence. The producer runs to completion (or cancellation); each
  /// `writer.write(_:)` becomes one HTTP chunk on the wire. Cancelling
  /// the surrounding stream (because the client disconnected) cancels
  /// the producer task via `continuation.onTermination`.
  private static func makeStreamingBody(
    producer: @escaping @Sendable (ResponseBodyWriter) async throws -> Void
  ) -> HTTPBodySequence {
    let (stream, continuation) = AsyncStream<Data>.makeStream(
      bufferingPolicy: .unbounded)
    let writer = StreamingWriter(continuation: continuation)
    let producerTask = Task {
      defer { continuation.finish() }
      do {
        try await producer(writer)
      } catch {
        // Producer threw mid-stream. Headers are already on the wire,
        // so we can't escalate to an HTTP error — the response just
        // terminates early. Matches Hummingbird's behavior for the
        // same case.
      }
    }
    continuation.onTermination = { _ in
      producerTask.cancel()
    }
    return HTTPBodySequence(from: PushBufferedSequence(stream: stream))
  }
}

/// Hummingbird's `Channel`/`SocketAddress` shape, narrowed to the two
/// properties the kit's `onServerRunning` closure reads. Named with a
/// `Server` prefix to avoid any collision with Network.framework or NIO
/// types that callers may also import.
struct ServerChannel: Sendable {
  let localAddress: ServerAddress?
}

struct ServerAddress: Sendable {
  let port: Int?
}

/// Concrete `ResponseBodyWriter` backed by the streaming `AsyncStream`
/// continuation. `write(_:)` is declared `async throws` for API parity
/// with Hummingbird's writer; the underlying yield is synchronous (the
/// stream uses an unbounded buffer), so the only cancellation point is
/// the producer's own `await` calls on its upstream sequence.
private struct StreamingWriter: ResponseBodyWriter {
  let continuation: AsyncStream<Data>.Continuation

  func write(_ buffer: ByteBuffer) async throws {
    continuation.yield(buffer.data)
  }

  func finish(_ trailers: HTTPFields?) async throws {
    continuation.finish()
  }
}

enum ApplicationError: Error {
  case invalidPort(Int)
}
