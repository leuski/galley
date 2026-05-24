//
//  HTTPTunnelAVPClientTests.swift
//  Galley — visionOS slice
//
//  Pin the WebKit-URL → `ProxyHTTPRequest` conversion. The wire
//  `urlPath` must match Hummingbird's route shape exactly
//  (`/preview/**`, `/template/**`, `/events/**`), and every request
//  carries `X-Galley-Origin: galley://local` so the Mac composes
//  `<base href>` on the same scheme — without it sub-resource fetches
//  resolve against `http://127.0.0.1:<port>/` and escape the scheme
//  handler. (The "no CSS in the AVP window" symptom.)
//

#if os(visionOS)
import Foundation
import GalleyCoreKit
import KosmosCore
import Testing
@testable import Galley

@Suite("HTTPTunnelAVPClient.buildProxyRequest")
struct HTTPTunnelAVPClientBuildRequestTests {
  @Test("galley://local/preview/<path> → urlPath = /preview/<path>")
  func documentPath() throws {
    let url = URL(
      string: "galley://local/preview/Users/x/Documents/foo.md")!
    let request = URLRequest(url: url)
    let proxy = try #require(HTTPTunnelAVPClient.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/preview/Users/x/Documents/foo.md")
    #expect(proxy.method == "GET")
  }

  @Test("galley://local/template/<id>/<file> → urlPath = /template/<id>/<file>")
  func templatePath() throws {
    let url = URL(
      string: "galley://local/template/galley.default/style.css")!
    let request = URLRequest(url: url)
    let proxy = try #require(HTTPTunnelAVPClient.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/template/galley.default/style.css")
  }

  @Test("galley://local/events/<path> preserves the SSE route prefix")
  func eventsPath() throws {
    let url = URL(string: "galley://local/events/Users/x/foo.md")!
    let request = URLRequest(url: url)
    let proxy = try #require(HTTPTunnelAVPClient.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/events/Users/x/foo.md")
  }

  @Test("percent-encoded path segments survive verbatim")
  func preservesEncodedPath() throws {
    let url = URL(string: "galley://local/preview/Users/x/Read%20Me.md")!
    let request = URLRequest(url: url)
    let proxy = try #require(HTTPTunnelAVPClient.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/preview/Users/x/Read%20Me.md")
  }

  @Test("query string is appended to urlPath")
  func preservesQuery() throws {
    let url = URL(
      string: "galley://local/preview/Users/x/foo.md?line=42")!
    let request = URLRequest(url: url)
    let proxy = try #require(HTTPTunnelAVPClient.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.urlPath == "/preview/Users/x/foo.md?line=42")
  }

  @Test("every request stamps X-Galley-Origin = galley://local")
  func injectsOriginHeader() throws {
    let url = URL(string: "galley://local/preview/Users/x/foo.md")!
    let request = URLRequest(url: url)
    let proxy = try #require(HTTPTunnelAVPClient.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.headers["X-Galley-Origin"] == "galley://local")
  }

  @Test("inbound Host header is dropped")
  func dropsHostHeader() throws {
    let url = URL(string: "galley://local/preview/Users/x/foo.md")!
    var request = URLRequest(url: url)
    request.setValue("local", forHTTPHeaderField: "Host")
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    let proxy = try #require(HTTPTunnelAVPClient.buildProxyRequest(
      requestID: UUID(), request: request, url: url))
    #expect(proxy.headers["Accept"] == "text/html")
    #expect(proxy.headers["Host"] == nil)
  }
}
#endif
