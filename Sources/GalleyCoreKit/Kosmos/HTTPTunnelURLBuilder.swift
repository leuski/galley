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
}
