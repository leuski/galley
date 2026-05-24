#if os(visionOS)
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

  /// Per-request state. Two kinds of work live here: yielding
  /// `URLSchemeTaskResult`s into the scheme handler's stream, and
  /// publishing a final `ProxyHTTPCancel` if the stream terminates
  /// before the responder finishes.
  private struct Entry {
    let continuation: AsyncThrowingStream<URLSchemeTaskResult, any Error>
      .Continuation
    let url: URL
    var sawHead: Bool
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
        sawHead: false)

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
  /// received a broadcast meant for another peer's request).
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
    inflight[head.requestID] = entry
  }

  func handle(_ chunk: ProxyHTTPResponseChunk) {
    guard let entry = inflight[chunk.requestID] else { return }
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
      entry.continuation.yield(.data(chunk.bytes))
    }
    if chunk.isFinal {
      entry.continuation.finish()
      inflight.removeValue(forKey: chunk.requestID)
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

  /// Convert a WebKit `URLRequest` (with a `galley://preview/...` URL)
  /// into a `ProxyHTTPRequest`. The path on the wire is the
  /// percent-encoded path + query of the original URL, with the
  /// `galley://preview` prefix stripped — the responder's loopback
  /// HTTP listener serves `/preview/<absolute-path>` and that's what
  /// it expects to see in `urlPath`.
  static func buildProxyRequest(
    requestID: UUID,
    request: URLRequest,
    url: URL
  ) -> ProxyHTTPRequest? {
    guard let components = URLComponents(
      url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let encodedPath = components.percentEncodedPath
    var urlPath = encodedPath
    if let query = components.percentEncodedQuery {
      urlPath += "?\(query)"
    }
    guard urlPath.hasPrefix("/") else { return nil }
    let headers = Self.collectHeaders(from: request)
    let body = request.httpBody ?? Data()
    return ProxyHTTPRequest(
      requestID: requestID,
      method: request.httpMethod ?? "GET",
      urlPath: urlPath,
      headers: headers,
      body: body)
  }

  static func collectHeaders(
    from request: URLRequest
  ) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      // `Host` is regenerated by the Mac responder; drop AVP's
      // `galley://...` host so it doesn't leak through.
      if name.caseInsensitiveCompare("Host") == .orderedSame { continue }
      headers[name] = value
    }
    return headers
  }
}
#endif
