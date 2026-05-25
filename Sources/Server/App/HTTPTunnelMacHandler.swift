import CryptoKit
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosTransport
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "HTTPTunnelMacHandler")

/// Mac side of the Galley HTTP tunnel.
///
/// Inbound: subscribes to `ProxyHTTPRequest` Kosmos broadcasts from
/// AVP peers. For each request, opens a `URLSessionDataTask` against
/// the local Hummingbird HTTP listener (`http://127.0.0.1:<port>`)
/// and streams the response back as `ProxyHTTPResponseHead` +
/// `ProxyHTTPResponseChunk` broadcasts. Maintains a `requestID →
/// in-flight task` map so an inbound `ProxyHTTPCancel` (typically
/// emitted by WebKit when a sub-resource load is cancelled or the
/// page navigates away mid-SSE) tears the upstream task down without
/// affecting unrelated requests.
///
/// One code path for both bounded and streaming responses. We use
/// `URLSessionDataDelegate` so the response head arrives before any
/// body byte; the head's `Content-Type` drives whether we accumulate
/// and chunk-on-completion (PNG / HTML / CSS / JS — works around
/// WebKit's `URLSchemeTask` multi-event delivery bug on the AVP
/// receiver) or forward each body batch as it lands (SSE — gives
/// `EventSource` line-level latency). Single source of truth:
/// `HTTPTunnelURLBuilder.isEventStream`.
///
/// Why broadcast and not unicast: Kosmos doesn't expose a public
/// per-peer publish on the `KosmosClient` API today, and Galley only
/// ever has at most one AVP peer at a time, so broadcasting the
/// response with the requestID as the correlator is simpler than
/// adding new transport surface area. The Mac Viewer peer also
/// subscribes to none of these tunnel messages, so it's a no-op there.
@MainActor
final class HTTPTunnelMacHandler {
  /// Base URL for the loopback HTTP listener — `http://127.0.0.1:<port>`.
  /// Read at request time so listener restarts (port changes) are
  /// picked up automatically.
  let upstreamBaseProvider: @MainActor () -> URL?

  /// Tasks for in-flight tunnel requests, keyed by `requestID`.
  /// Cancelled on inbound `ProxyHTTPCancel` or on `stop()`.
  private var inflight: [UUID: Task<Void, Never>] = [:]

  /// Dedicated session for tunneled fetches. Ephemeral config —
  /// no shared cache, no cookies. The body bytes flow back over
  /// Kosmos so caching at the Mac doesn't help anyone. Per-task
  /// delegates handle the head + batch + completion stream; we
  /// don't set a session-wide delegate.
  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    // Per-task `URLRequest.timeoutInterval` is set to infinity in
    // `tunnel(...)` so SSE doesn't die at 60s, and so loopback
    // Hummingbird gets to deliver however many bytes it has.
    config.timeoutIntervalForResource = .greatestFiniteMagnitude
    return URLSession(configuration: config)
  }()

  init(upstreamBaseProvider: @escaping @MainActor () -> URL?) {
    self.upstreamBaseProvider = upstreamBaseProvider
  }

  func handleRequest(_ request: ProxyHTTPRequest, client: KosmosClient) {
    let task = Task { @MainActor [weak self] in
      await self?.process(request: request, client: client)
      self?.inflight.removeValue(forKey: request.requestID)
    }
    inflight[request.requestID] = task
  }

  func handleCancel(_ cancel: ProxyHTTPCancel) {
    inflight.removeValue(forKey: cancel.requestID)?.cancel()
  }

  /// Cancel every in-flight tunnel task. Called when the Kosmos
  /// session goes down or when the listener is being torn down.
  func stop() {
    for (_, task) in inflight { task.cancel() }
    inflight.removeAll()
  }

  // MARK: - Tunnel pipeline

  private func process(
    request: ProxyHTTPRequest, client: KosmosClient
  ) async {
    guard let base = upstreamBaseProvider() else {
      await publishError(
        requestID: request.requestID, status: 503,
        message: "Loopback HTTP listener not bound.", client: client)
      return
    }
    guard let urlRequest = HTTPTunnelURLBuilder.buildURLRequest(
      base: base, request: request)
    else {
      await publishError(
        requestID: request.requestID, status: 400,
        message: "Invalid tunnel request URL: \(request.urlPath)",
        client: client)
      return
    }

    log.notice("""
      → TUNNEL \(request.method, privacy: .public) \
      \(request.urlPath, privacy: .public) \
      requestID=\(request.requestID, privacy: .public)
      """)

    do {
      try await tunnel(
        requestID: request.requestID,
        urlPath: request.urlPath,
        urlRequest: urlRequest,
        client: client)
    } catch is CancellationError {
      // AVP cancelled (page navigated away, WebKit dropped the
      // sub-resource). The data task is auto-cancelled via `defer`
      // in `tunnel(...)`; no synthetic response needed since the
      // AVP receiver isn't listening for it anymore.
      log.notice("""
        TUNNEL cancelled requestID=\(request.requestID, privacy: .public)
        """)
    } catch {
      log.error("""
        TUNNEL failed requestID=\(request.requestID, privacy: .public) \
        error=\(error.localizedDescription, privacy: .public)
        """)
      await publishError(
        requestID: request.requestID,
        status: 502,
        message: "Tunnel error: \(error.localizedDescription)",
        client: client)
    }
  }

  /// Unified tunnel pipeline. Drives one upstream `URLSessionDataTask`
  /// through a delegate that surfaces head + per-batch body + final
  /// completion as a typed `AsyncThrowingStream`. Once the head
  /// arrives we know whether the response is an event stream and
  /// route the body accordingly:
  ///
  /// - **Bounded** (HTML, CSS, JS, images): accumulate all batches
  ///   into a single buffer, then slice via `HTTPTunnelURLBuilder.chunks`
  ///   and publish each. The AVP receiver coalesces them back into
  ///   a single `.data(...)` yield to WebKit — workaround for the
  ///   `URLSchemeTask` multi-event delivery bug.
  /// - **Streaming** (`text/event-stream`): publish each delegate
  ///   batch as its own chunk so `EventSource` on AVP sees events
  ///   as the producer emits them. `timeoutInterval = infinity` on
  ///   the request keeps a quiet stream alive past 60s.
  ///
  /// SHA-256 prefix in the completion log lets us cross-check the
  /// AVP receiver's hash without re-buffering the whole body just
  /// to digest it.
  private func tunnel(
    requestID: UUID,
    urlPath: String,
    urlRequest: URLRequest,
    client: KosmosClient
  ) async throws {
    var request = urlRequest
    // Loopback Hummingbird never wedges, but SSE legitimately sits
    // idle for long stretches. Disable per-request timeouts so we
    // don't kill quiet event streams at 60s — the configuration
    // default that applies to bounded fetches.
    request.timeoutInterval = .greatestFiniteMagnitude

    let (events, continuation) =
      AsyncThrowingStream<TunnelDataDelegate.Event, any Error>
        .makeStream()
    let delegate = TunnelDataDelegate(continuation: continuation)
    let task = session.dataTask(with: request)
    task.delegate = delegate
    task.resume()
    defer { task.cancel() }

    var isStreaming = false
    var status = 502
    var buffer = Data()
    var sequence: UInt64 = 0
    var totalBytes = 0
    var hasher = SHA256()

    for try await event in events {
      try Task.checkCancellation()
      switch event {
      case .head(let response):
        status = response.statusCode
        let headers = HTTPTunnelURLBuilder.extractHeaders(from: response)
        isStreaming = HTTPTunnelURLBuilder.isEventStream(headers)
        await client.publish(ProxyHTTPResponseHead(
          requestID: requestID,
          status: status,
          headers: headers))

      case .batch(let data):
        hasher.update(data: data)
        totalBytes += data.count
        if isStreaming {
          await client.publish(ProxyHTTPResponseChunk(
            requestID: requestID,
            sequence: sequence,
            bytes: data,
            isFinal: false))
          sequence += 1
        } else {
          buffer.append(data)
        }
      }
    }

    sequence = try await finalize(
      requestID: requestID,
      buffer: buffer,
      isStreaming: isStreaming,
      startSequence: sequence,
      client: client)

    let digest = hasher.finalize().prefix(4)
      .map { String(format: "%02x", $0) }
      .joined()
    log.notice("""
      TUNNEL done requestID=\(requestID, privacy: .public) \
      path=\(urlPath, privacy: .public) \
      status=\(status, privacy: .public) \
      streaming=\(isStreaming, privacy: .public) \
      bytes=\(totalBytes, privacy: .public) \
      chunks=\(sequence, privacy: .public) \
      sha256-prefix=\(digest, privacy: .public)
      """)
  }

  /// Flush whatever's left after the upstream event loop has run
  /// to completion and emit the terminator chunk. Bounded responses
  /// slice the accumulated buffer with `HTTPTunnelURLBuilder.chunks`;
  /// event streams just publish an empty `isFinal: true` chunk so
  /// the AVP receiver can finalize its `URLSchemeTask`. Returns the
  /// total chunks emitted (for the completion log).
  private func finalize(
    requestID: UUID,
    buffer: Data,
    isStreaming: Bool,
    startSequence: UInt64,
    client: KosmosClient
  ) async throws -> UInt64 {
    if isStreaming {
      await client.publish(ProxyHTTPResponseChunk(
        requestID: requestID,
        sequence: startSequence,
        bytes: Data(),
        isFinal: true))
      return startSequence + 1
    }
    // 64 KB matches typical URLSession internal batches and is
    // well below any Kosmos message ceiling.
    let chunks = HTTPTunnelURLBuilder.chunks(
      of: buffer, requestID: requestID, chunkSize: 64 * 1024)
    for chunk in chunks {
      try Task.checkCancellation()
      await client.publish(chunk)
    }
    return UInt64(chunks.count)
  }

  /// Publish a synthetic error response so the AVP-side scheme
  /// handler can finalize the `URLSchemeTask` cleanly rather than
  /// timing out.
  private func publishError(
    requestID: UUID, status: Int, message: String, client: KosmosClient
  ) async {
    await client.publish(ProxyHTTPResponseHead(
      requestID: requestID,
      status: status,
      headers: ["Content-Type": "text/plain; charset=utf-8"]))
    await client.publish(ProxyHTTPResponseChunk(
      requestID: requestID,
      sequence: 0,
      bytes: Data(message.utf8),
      isFinal: true))
  }
}

/// `URLSessionDataDelegate` that bridges the head + per-batch body +
/// completion lifecycle into an `AsyncThrowingStream`. Kept separate
/// from `HTTPTunnelMacHandler` because URLSession invokes delegate
/// methods from arbitrary queues — the handler is `@MainActor`, so
/// the delegate has to be `Sendable` on its own.
///
/// Lifetime: the delegate is retained by the `URLSessionDataTask`
/// via `task.delegate = self`. Tunnel completion (success / error /
/// cancellation) finishes the continuation and releases the strong
/// graph.
private final class TunnelDataDelegate:
  NSObject, URLSessionDataDelegate, @unchecked Sendable
{
  enum Event: Sendable {
    case head(HTTPURLResponse)
    case batch(Data)
  }

  private let continuation:
    AsyncThrowingStream<Event, any Error>.Continuation

  init(
    continuation: AsyncThrowingStream<Event, any Error>.Continuation
  ) {
    self.continuation = continuation
    super.init()
  }

  // MARK: URLSessionDataDelegate

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable
      (URLSession.ResponseDisposition) -> Void
  ) {
    if let httpResponse = response as? HTTPURLResponse {
      continuation.yield(.head(httpResponse))
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    continuation.yield(.batch(data))
  }

  // MARK: URLSessionTaskDelegate

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }
}
