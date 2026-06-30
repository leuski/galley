//
//  HTTPTunnelAVPClientTests.swift
//  Galley — visionOS slice
//
//  Pin the WebKit-URL → `ProxyHTTPRequest` conversion. The decoded
//  `path` must match Hummingbird's route shape exactly (`/preview/**`,
//  `/template/**`, `/events/**`), the query must land in `queryItems`,
//  and headers stamped by the scheme handler — notably
//  `X-Kosmos-Origin: kosmos://local` — must reach the proxy verbatim.
//  Without the origin header sub-resource fetches resolve against
//  `http://127.0.0.1:<port>/` and escape the scheme handler ("no CSS in
//  the AVP window").
//

#if os(visionOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosHTTPTunnel
import Testing
@testable import Galley

@Suite("ProxyHTTPRequest(request:url:)")
struct HTTPTunnelAVPClientBuildRequestTests {
  private func proxy(for urlString: String) throws -> ProxyHTTPRequest {
    let url = try #require(URL(string: urlString))
    return try #require(ProxyHTTPRequest(
      requestID: UUID(), request: URLRequest(url: url), url: url))
  }

  @Test("kosmos://local/preview/<path> → path = /preview/<path>")
  func documentPath() throws {
    let proxy = try proxy(for: "kosmos://local/preview/Users/x/Documents/foo.md")
    #expect(proxy.path == "/preview/Users/x/Documents/foo.md")
    #expect(proxy.method == "GET")
  }

  @Test("kosmos://local/template/<id>/<file> → path = /template/<id>/<file>")
  func templatePath() throws {
    let proxy = try proxy(
      for: "kosmos://local/template/galley.default/style.css")
    #expect(proxy.path == "/template/galley.default/style.css")
  }

  @Test("kosmos://local/events/<path> preserves the SSE route prefix")
  func eventsPath() throws {
    let proxy = try proxy(for: "kosmos://local/events/Users/x/foo.md")
    #expect(proxy.path == "/events/Users/x/foo.md")
  }

  @Test("percent-encoded path segments arrive decoded")
  func decodesEncodedPath() throws {
    let proxy = try proxy(for: "kosmos://local/preview/Users/x/Read%20Me.md")
    #expect(proxy.path == "/preview/Users/x/Read Me.md")
  }

  @Test("query string lands in queryItems, not the path")
  func separatesQuery() throws {
    let proxy = try proxy(for: "kosmos://local/preview/Users/x/foo.md?line=42")
    #expect(proxy.path == "/preview/Users/x/foo.md")
    #expect(proxy.queryItems == [URLQueryItem(name: "line", value: "42")])
  }

  @Test("scheme-handler-stamped origin header is forwarded verbatim")
  func forwardsOriginHeader() throws {
    let url = try #require(URL(string: "kosmos://local/preview/Users/x/foo.md"))
    var request = URLRequest(url: url)
    request.setValue(
      TunnelScheme.originURL.absoluteString,
      forHTTPHeaderField: TunnelHeaders.origin)
    let proxy = try #require(ProxyHTTPRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.headers[TunnelHeaders.origin] == "kosmos://local")
  }

  @Test("inbound Host header is dropped")
  func dropsHostHeader() throws {
    let url = try #require(URL(string: "kosmos://local/preview/Users/x/foo.md"))
    var request = URLRequest(url: url)
    request.setValue("local", forHTTPHeaderField: "Host")
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    let proxy = try #require(ProxyHTTPRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.headers["Accept"] == "text/html")
    #expect(proxy.headers["Host"] == nil)
  }
}

#endif
