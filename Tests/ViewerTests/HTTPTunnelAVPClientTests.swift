//
//  HTTPTunnelAVPClientTests.swift
//  Galley — visionOS slice
//
//  Pin the WebKit-URL → `ProxyHTTPRequest` conversion. The wire
//  `urlPath` must match Hummingbird's route shape exactly
//  (`/preview/**`, `/template/**`, `/events/**`), and headers stamped
//  by the scheme handler — notably `X-Kosmos-Origin: kosmos://local` —
//  must reach the proxy verbatim. Without the origin header sub-resource
//  fetches resolve against `http://127.0.0.1:<port>/` and escape the
//  scheme handler ("no CSS in the AVP window").
//

#if os(visionOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosHTTPTunnel
import Testing
@testable import Galley

@Suite("KosmosHTTPTunnel.Client.buildProxyRequest")
struct HTTPTunnelAVPClientBuildRequestTests {
  @Test("kosmos://local/preview/<path> → urlPath = /preview/<path>")
  func documentPath() throws {
    let url = URL(
      string: "kosmos://local/preview/Users/x/Documents/foo.md")!
    let request = URLRequest(url: url)
    let proxy = try #require(Client.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/preview/Users/x/Documents/foo.md")
    #expect(proxy.method == "GET")
  }

  @Test("kosmos://local/template/<id>/<file> → urlPath = /template/<id>/<file>")
  func templatePath() throws {
    let url = URL(
      string: "kosmos://local/template/galley.default/style.css")!
    let request = URLRequest(url: url)
    let proxy = try #require(Client.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/template/galley.default/style.css")
  }

  @Test("kosmos://local/events/<path> preserves the SSE route prefix")
  func eventsPath() throws {
    let url = URL(string: "kosmos://local/events/Users/x/foo.md")!
    let request = URLRequest(url: url)
    let proxy = try #require(Client.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/events/Users/x/foo.md")
  }

  @Test("percent-encoded path segments survive verbatim")
  func preservesEncodedPath() throws {
    let url = URL(string: "kosmos://local/preview/Users/x/Read%20Me.md")!
    let request = URLRequest(url: url)
    let proxy = try #require(Client.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/preview/Users/x/Read%20Me.md")
  }

  @Test("query string is appended to urlPath")
  func preservesQuery() throws {
    let url = URL(
      string: "kosmos://local/preview/Users/x/foo.md?line=42")!
    let request = URLRequest(url: url)
    let proxy = try #require(Client.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/preview/Users/x/foo.md?line=42")
  }

  @Test("scheme-handler-stamped origin header is forwarded verbatim")
  func forwardsOriginHeader() throws {
    let url = URL(string: "kosmos://local/preview/Users/x/foo.md")!
    var request = URLRequest(url: url)
    request.setValue(
      TunnelScheme.originURL.absoluteString,
      forHTTPHeaderField: TunnelHeaders.origin)
    let proxy = try #require(Client.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.headers[TunnelHeaders.origin] == "kosmos://local")
  }

  @Test("inbound Host header is dropped")
  func dropsHostHeader() throws {
    let url = URL(string: "kosmos://local/preview/Users/x/foo.md")!
    var request = URLRequest(url: url)
    request.setValue("local", forHTTPHeaderField: "Host")
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    let proxy = try #require(Client.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.headers["Accept"] == "text/html")
    #expect(proxy.headers["Host"] == nil)
  }
}

#endif
