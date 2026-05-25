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
    for (name, value) in request.headers {
      if name.caseInsensitiveCompare("Host") == .orderedSame { continue }
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
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

  /// Whether a tunneled URL path should be served via streaming
  /// (per-byte) iteration rather than buffered fetch. Today only the
  /// SSE event-stream routes need streaming; every other path is a
  /// finite response and benefits from the fast buffered path.
  public static func requiresStreaming(urlPath: String) -> Bool {
    urlPath.hasPrefix("/events/") || urlPath == "/events"
  }
}
