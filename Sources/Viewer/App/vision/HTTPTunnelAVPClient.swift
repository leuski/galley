#if os(visionOS)
import CryptoKit
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosTransport
import OSLog
import WebKit

private let log = Logger(
  subsystem: bundleIdentifier, category: "HTTPTunnelAVPClient")

/// AVP side of the Galley HTTP tunnel. Sends `ProxyHTTPRequest`s on
/// behalf of `KosmosTunnelSchemeHandler` and routes inbound
/// `ProxyHTTPResponseHead` / `ProxyHTTPResponseChunk` broadcasts back
/// to the right outstanding request via a `requestID → continuation`
/// map.
///
/// A single shared subscription (per Kosmos session) fans messages
/// out to per-request continuations — better than spinning up a
/// fresh subscription per WebKit request.
///
/// Concurrency: `@MainActor`. All entry points (open / cancel / the
/// two response-message handlers) run on the main actor; the
/// scheme handler's stream callbacks hop back via Task wrappers.
@MainActor
final class HTTPTunnelAVPClient {
  private weak var client: KosmosClient?

  /// Per-request state. Three jobs live here:
  ///
  /// 1. Yield `URLSchemeTaskResult`s into the scheme handler's
  ///    stream. For ordinary (bounded) responses we accumulate every
  ///    chunk in `buffer` and yield exactly one `.data(buffer)` when
  ///    the final chunk arrives — WebKit's `URLSchemeTask` doesn't
  ///    reliably deliver multi-event `.data(...)` payloads (PNG /
  ///    JS decoders see the bytes truncated even when the tunnel
  ///    delivers them bit-exact). For streaming responses
  ///    (`Content-Type: text/event-stream`) `isStreaming` is set
  ///    when the response head arrives and each chunk yields
  ///    immediately so `EventSource` gets line-level latency.
  ///
  /// 2. Publish a final `ProxyHTTPCancel` if the WebKit stream
  ///    terminates before the responder finishes (via
  ///    `continuation.onTermination`).
  ///
  /// 3. Diagnostic accounting (`bytesYielded` / `chunksRouted` /
  ///    `hasher`) logged at completion — lets us cross-check the
  ///    Mac responder's "bytes / chunks / sha256-prefix" totals.
  private struct Entry {
    let continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>
      .Continuation
    let url: URL
    var sawHead: Bool
    var isStreaming: Bool
    var bytesYielded: Int
    var chunksRouted: Int
    var hasher: SHA256
    var buffer: Data
  }
  private var inflight: [UUID: Entry] = [:]

  init(client: KosmosClient?) {
    self.client = client
  }

  /// Replace the weak `client` reference. Called from
  /// `KosmosVisionService.bootstrap()` once the live `KosmosClient`
  /// is materialized.
  func attach(client: KosmosClient) {
    self.client = client
  }

  /// Send a fresh `ProxyHTTPRequest` for `request` and hand back an
  /// `AsyncThrowingStream` the scheme handler yields directly to
  /// WebKit. The stream finishes when the responder sends an
  /// `isFinal` chunk. Stream-termination (WebKit cancel, page
  /// navigation away) publishes a `ProxyHTTPCancel` and clears the
  /// entry.
  func openTunnel(
    for request: URLRequest
  ) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
    let requestID = UUID()
    let url = request.url

    return AsyncThrowingStream { continuation in
      guard
        let url,
        let proxyRequest = Self.buildProxyRequest(
          requestID: requestID, request: request, url: url)
      else {
        continuation.finish(throwing: URLError(.badURL))
        return
      }

      self.inflight[requestID] = Entry(
        continuation: continuation,
        url: url,
        sawHead: false,
        isStreaming: false,
        bytesYielded: 0,
        chunksRouted: 0,
        hasher: SHA256(),
        buffer: Data())

      log.notice("""
        → TUNNEL \(proxyRequest.method, privacy: .public) \
        \(proxyRequest.urlPath, privacy: .public) \
        requestID=\(requestID, privacy: .public)
        """)

      Task { [weak client] in
        await client?.publish(proxyRequest)
      }

      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          self?.cancel(requestID: requestID)
        }
      }
    }
  }

  /// Route an inbound response head into the matching entry's
  /// continuation. Drops the message if the requestID isn't in
  /// `inflight` (the request was already cancelled, or this peer
  /// received a broadcast meant for another peer's request). The
  /// head's `Content-Type` decides whether subsequent chunks
  /// stream (event-stream) or buffer until `isFinal`.
  func handle(_ head: ProxyHTTPResponseHead) {
    guard var entry = inflight[head.requestID] else { return }
    guard let response = HTTPURLResponse(
      url: entry.url,
      statusCode: head.status,
      httpVersion: "HTTP/1.1",
      headerFields: head.headers)
    else {
      entry.continuation.finish(throwing: URLError(.cannotParseResponse))
      inflight.removeValue(forKey: head.requestID)
      return
    }
    entry.continuation.yield(.response(response))
    entry.sawHead = true
    entry.isStreaming = Self.isEventStream(head.headers)
    inflight[head.requestID] = entry
  }

  /// Whether the response head signals a long-lived event stream
  /// the receiver should consume incrementally rather than buffer.
  /// Case-insensitive scan of the `Content-Type` header. Matches
  /// `text/event-stream` with or without parameters
  /// (`; charset=utf-8` etc.).
  nonisolated static func isEventStream(
    _ headers: [String: String]
  ) -> Bool {
    let value = headers.first { name, _ in
      name.caseInsensitiveCompare("Content-Type") == .orderedSame
    }?.value ?? ""
    let trimmed = value
      .split(separator: ";", maxSplits: 1)
      .first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? value
    return trimmed.caseInsensitiveCompare("text/event-stream")
      == .orderedSame
  }

  func handle(_ chunk: ProxyHTTPResponseChunk) {
    guard var entry = inflight[chunk.requestID] else { return }
    // The Mac responder always sends a head before any chunks. If
    // we somehow received chunks before a head, drop the entry and
    // let WebKit see a cancellation — a missing head is fatal for
    // the URLSchemeTask state machine.
    guard entry.sawHead else {
      entry.continuation.finish(throwing: URLError(.cannotParseResponse))
      inflight.removeValue(forKey: chunk.requestID)
      Task { [weak client] in
        await client?.publish(ProxyHTTPCancel(requestID: chunk.requestID))
      }
      return
    }
    if !chunk.bytes.isEmpty {
      if entry.isStreaming {
        // Event-stream: deliver each chunk immediately so
        // `EventSource` sees events as the producer emits them.
        entry.continuation.yield(.data(chunk.bytes))
      } else {
        // Bounded response: accumulate; single `.data` yield on
        // `isFinal` works around WebKit's `URLSchemeTask` not
        // reliably delivering multi-event `.data(...)` payloads.
        entry.buffer.append(chunk.bytes)
      }
      entry.bytesYielded += chunk.bytes.count
      entry.hasher.update(data: chunk.bytes)
    }
    entry.chunksRouted += 1
    if chunk.isFinal {
      if !entry.isStreaming, !entry.buffer.isEmpty {
        entry.continuation.yield(.data(entry.buffer))
      }
      entry.continuation.finish()
      let digest = entry.hasher.finalize().prefix(4)
        .map { String(format: "%02x", $0) }
        .joined()
      log.notice("""
        TUNNEL done requestID=\(chunk.requestID, privacy: .public) \
        url=\(entry.url.absoluteString, privacy: .public) \
        streaming=\(entry.isStreaming, privacy: .public) \
        bytes=\(entry.bytesYielded, privacy: .public) \
        chunks=\(entry.chunksRouted, privacy: .public) \
        sha256-prefix=\(digest, privacy: .public)
        """)
      inflight.removeValue(forKey: chunk.requestID)
    } else {
      inflight[chunk.requestID] = entry
    }
  }

  /// Publish a cancel and drop the entry. Called via continuation
  /// `onTermination` (WebKit gave up on the request) and on
  /// `stop()`. Idempotent against the inflight map.
  private func cancel(requestID: UUID) {
    guard inflight.removeValue(forKey: requestID) != nil else { return }
    log.notice("""
      → TUNNEL cancel requestID=\(requestID, privacy: .public)
      """)
    Task { [weak client] in
      await client?.publish(ProxyHTTPCancel(requestID: requestID))
    }
  }

  /// Drop every outstanding request — typically called when the
  /// Kosmos session restarts or the service stops. Each pending
  /// stream finishes with a cancellation error so WebKit can
  /// clean up.
  func stopAll() {
    for (_, entry) in inflight {
      entry.continuation.finish(throwing: CancellationError())
    }
    inflight.removeAll()
  }

  // MARK: - URL → ProxyHTTPRequest

  /// Convert a WebKit `URLRequest` (with a
  /// `galley://local/<route>/<path>` URL) into a `ProxyHTTPRequest`.
  ///
  /// The wire `urlPath` is the percent-encoded path verbatim — the
  /// sentinel host (`local`) is discarded and the path already
  /// includes the route prefix (`/preview/<...>` or `/template/<...>`
  /// or `/events/<...>`). Hummingbird matches its `/preview/**` /
  /// `/template/**` / `/events/**` routes against this directly.
  ///
  /// Every request is stamped with `X-Galley-Origin: galley://local`
  /// so the Mac's `templateOriginURL` returns the scheme origin
  /// instead of the loopback HTTP authority. The Server's
  /// `<base href>` then carries `galley://local/preview/<docparent>/`,
  /// which keeps every sub-resource fetch on this scheme handler.
  nonisolated static func buildProxyRequest(
    requestID: UUID,
    request: URLRequest,
    url: URL
  ) -> ProxyHTTPRequest? {
    guard
      let components = URLComponents(
        url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    var urlPath = components.percentEncodedPath
    if let query = components.percentEncodedQuery {
      urlPath += "?\(query)"
    }
    guard urlPath.hasPrefix("/") else { return nil }
    var headers = Self.collectHeaders(from: request)
    headers["X-Galley-Origin"] = KosmosTunnelScheme.originURL.absoluteString
    let body = request.httpBody ?? Data()
    return ProxyHTTPRequest(
      requestID: requestID,
      method: request.httpMethod ?? "GET",
      urlPath: urlPath,
      headers: headers,
      body: body)
  }

  nonisolated static func collectHeaders(
    from request: URLRequest
  ) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      // `Host` is regenerated by the Mac responder; drop AVP's
      // `galley://local` host so it doesn't leak through.
      if name.caseInsensitiveCompare("Host") == .orderedSame { continue }
      headers[name] = value
    }
    return headers
  }
}
#endif
