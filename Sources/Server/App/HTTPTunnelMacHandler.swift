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
/// AVP peers. For each request, opens a `URLSession` data task against
/// the local Hummingbird HTTP listener (`http://127.0.0.1:<port>`),
/// streams the response back as `ProxyHTTPResponseHead` +
/// `ProxyHTTPResponseChunk` broadcasts. Maintains a `requestID →
/// in-flight task` map so an inbound `ProxyHTTPCancel` (typically
/// emitted by WebKit when a sub-resource load is cancelled or the
/// page navigates away mid-SSE) tears the upstream task down without
/// affecting unrelated requests.
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
  /// Kosmos so caching at the Mac doesn't help anyone.
  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    // SSE streams stay open indefinitely; the resource timeout
    // shouldn't kill a long-lived event stream.
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
      let (bytes, response) = try await session.bytes(for: urlRequest)
      try Task.checkCancellation()
      let httpResponse = response as? HTTPURLResponse
      let status = httpResponse?.statusCode ?? 502
      let headers = HTTPTunnelURLBuilder.extractHeaders(from: httpResponse)
      await client.publish(ProxyHTTPResponseHead(
        requestID: request.requestID,
        status: status, headers: headers))

      // 64 KB chunk size matches typical URLSession internal batches
      // and is well below any Kosmos message ceiling.
      try await streamBody(
        requestID: request.requestID,
        bytes: bytes,
        chunkSize: 64 * 1024,
        client: client)
    } catch is CancellationError {
      // AVP cancelled (page navigated away, WebKit dropped the
      // sub-resource). Don't emit a final chunk — the receiver isn't
      // listening for it. The URLSession task is auto-cancelled when
      // the enclosing Task is cancelled and the `bytes` async sequence
      // exits.
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

  /// Drain `bytes` into chunked `ProxyHTTPResponseChunk` publishes.
  /// Each batch is at most `chunkSize`; the final batch sets
  /// `isFinal: true` even when empty so the receiver can finalize the
  /// `URLSchemeTask`.
  private func streamBody(
    requestID: UUID,
    bytes: URLSession.AsyncBytes,
    chunkSize: Int,
    client: KosmosClient
  ) async throws {
    var buffer = Data()
    buffer.reserveCapacity(chunkSize)
    var sequence: UInt64 = 0
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= chunkSize {
        await client.publish(ProxyHTTPResponseChunk(
          requestID: requestID,
          sequence: sequence,
          bytes: buffer,
          isFinal: false))
        sequence += 1
        buffer.removeAll(keepingCapacity: true)
        try Task.checkCancellation()
      }
    }
    // Final flush — may carry a tail of bytes or be empty.
    await client.publish(ProxyHTTPResponseChunk(
      requestID: requestID,
      sequence: sequence,
      bytes: buffer,
      isFinal: true))
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
