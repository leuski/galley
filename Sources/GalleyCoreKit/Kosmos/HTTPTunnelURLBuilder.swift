import Foundation
import KosmosCore

/// Pure helpers for the Galley HTTP tunnel. Both ends use them:
///
/// - Mac (responder) builds a `URLRequest` from an inbound
///   `ProxyHTTPRequest` to issue against its loopback HTTP server.
/// - Headers from a real `HTTPURLResponse` get folded into the
///   `[String: String]` shape `ProxyHTTPResponseHead` carries.
///
/// Kept in `GalleyCoreKit` rather than the Server target so they can
/// be unit-tested without importing the Server app bundle.
public enum HTTPTunnelURLBuilder {

  /// Splice an inbound `urlPath` onto a base URL and produce a
  /// `URLRequest` carrying the original method + headers + body.
  ///
  /// - `base` is the responder's loopback endpoint, e.g.
  ///   `http://127.0.0.1:54775`.
  /// - `urlPath` is path + (optional) query, must begin with `/`. The
  ///   path and the query are stitched onto `base` without further
  ///   percent-encoding — both sides agree the wire form is already
  ///   encoded as the original WebKit request had it.
  /// - `Host` is dropped from the inbound headers; the responder
  ///   supplies its own from `base`.
  ///
  /// Returns `nil` on a malformed `urlPath` (missing leading `/`) or
  /// when components can't be reassembled into a URL.
  public static func buildURLRequest(
    base: URL,
    request: ProxyHTTPRequest
  ) -> URLRequest? {
    guard
      var components = URLComponents(
        url: base, resolvingAgainstBaseURL: false),
      request.urlPath.hasPrefix("/")
    else { return nil }
    let pathAndQuery = request.urlPath.split(
      separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    components.percentEncodedPath = String(pathAndQuery[0])
    components.percentEncodedQuery = pathAndQuery.count > 1
      ? String(pathAndQuery[1]) : nil
    guard let url = components.url else { return nil }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    request.headers
      .filter { $0.key.lowercased() != "Host".lowercased() }
      .forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
    if !request.body.isEmpty {
      urlRequest.httpBody = request.body
    }
    return urlRequest
  }

  /// Pull `[String: String]` headers off an `HTTPURLResponse`. Names
  /// preserved as the upstream sent them, values verbatim. Non-string
  /// keys/values (rare; HTTPURLResponse is permissive on the type
  /// signature) are dropped.
  public static func extractHeaders(
    from response: HTTPURLResponse?
  ) -> [String: String] {
    guard let response else { return [:] }
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      guard let name = key as? String, let value = value as? String
      else { continue }
      headers[name] = value
    }
    return headers
  }

  /// Slice an already-buffered response body into chunked
  /// `ProxyHTTPResponseChunk` messages. `sequence` starts at 0 and
  /// increments; the last chunk carries `isFinal: true`. An empty
  /// body produces exactly one chunk with empty bytes and
  /// `isFinal: true` so the receiver always sees a terminator.
  ///
  /// Used by the Mac responder when the upstream request isn't an
  /// event-stream — buffering the whole body and chunking once is
  /// orders of magnitude faster than per-byte iteration over
  /// `URLSession.AsyncBytes`. SSE keeps the streaming path so events
  /// reach the receiver as they're produced.
  public static func chunks(
    of data: Data,
    requestID: UUID,
    chunkSize: Int
  ) -> [ProxyHTTPResponseChunk] {
    precondition(chunkSize > 0, "chunkSize must be positive")
    if data.isEmpty {
      return [ProxyHTTPResponseChunk(
        requestID: requestID,
        sequence: 0,
        bytes: Data(),
        isFinal: true)]
    }
    var chunks: [ProxyHTTPResponseChunk] = []
    var offset = 0
    var sequence: UInt64 = 0
    while offset < data.count {
      let end = min(offset + chunkSize, data.count)
      let slice = Data(data[offset..<end])
      chunks.append(ProxyHTTPResponseChunk(
        requestID: requestID,
        sequence: sequence,
        bytes: slice,
        isFinal: end == data.count))
      offset = end
      sequence += 1
    }
    return chunks
  }

  /// Whether a response head signals a long-lived event stream the
  /// receiver should consume incrementally instead of buffering. The
  /// single source of truth for streaming detection on both the Mac
  /// responder (chooses buffered vs per-batch chunk publishing) and
  /// the AVP receiver (chooses buffered single-yield vs per-chunk
  /// yield into WebKit).
  ///
  /// Case-insensitive on both header name and value. Honors
  /// parameters like `; charset=utf-8`. Galley's server only ever
  /// sets this Content-Type on the `/events/` SSE route, but the
  /// predicate is route-agnostic: any future endpoint that returns
  /// `text/event-stream` will be detected without code change.
  public static func isEventStream(
    _ headers: [String: String]
  ) -> Bool {
    let value = headers.first { name, _ in
      name.lowercased() == "Content-Type".lowercased()
    }?.value ?? ""
    let mediaType = value
      .split(separator: ";", maxSplits: 1)
      .first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? value
    return mediaType.lowercased() == "text/event-stream".lowercased()
  }
}
