//
//  AVPCSSPathChainTests.swift
//
//  End-to-end lockdown for the "Show on Vision Pro" path-encoding
//  contract. The user-visible failure mode this defends against is
//  CSS / images failing to load in the AVP window when a document
//  path contains characters that need percent-encoding.
//
//  Each layer of the AVP fetch path is unit-tested in isolation:
//
//    KosmosTunnelSchemeTests          → URL construction
//    HTTPTunnelAVPClientTests         → URL → ProxyHTTPRequest (AVP)
//    KosmosKit URLBuilderTests        → ProxyHTTPRequest → URLRequest (Mac)
//    TemplateOriginURLTests           → X-Kosmos-Origin → base href
//    RoutePathDecodingTests           → /preview/<encoded> → file URL
//
//  This file chains the pure value-type layers (everything except
//  the AVP-side scheme handler, which only compiles on visionOS) so
//  any regression in the encoding contract — extra encoding, dropped
//  encoding, route-prefix splicing — surfaces as a single failing
//  assertion with a clear reference shape.
//

import Foundation
import KosmosCore
import KosmosHTTPTunnel
import Testing
@testable import GalleyCoreKit

@Suite("AVP CSS path: scheme → tunnel URL → loopback URL")
struct AVPCSSPathChainTests {
  /// Reference document with a path segment that needs encoding —
  /// the case the original CSS regression was reported against.
  /// Result of running the document through every wire layer should
  /// land on the loopback HTTP server with the path verbatim.
  @Test("a document path with a space round-trips correctly")
  func documentWithSpace() throws {
    let documentPath = "/Users/x/Documents/Read Me.md"

    // Layer 1: AVP synthesizes the navigation URL.
    let tunnelURL = TunnelScheme.originURL.appending(
      .documentAsset(URL(fileURLWithPath: documentPath)))
    #expect(tunnelURL.absoluteString
      == "kosmos://local/preview/Users/x/Documents/Read%20Me.md")

    // Layer 2: AVP scheme handler folds the URL into a `ProxyHTTPRequest`.
    // The path travels *decoded* (`URLComponents.path`); percent-encoding
    // is the responder's concern, not the wire's.
    let proxy = try #require(makeProxy(forURL: tunnelURL))
    #expect(proxy.path == "/preview/Users/x/Documents/Read Me.md")

    // Layer 3: Mac re-encodes the decoded path onto the loopback base.
    let base = URL(string: "http://127.0.0.1:54775")!
    let urlRequest = try #require(proxy.urlRequest(base: base))
    #expect(urlRequest.url?.absoluteString
      == "http://127.0.0.1:54775/preview/Users/x/Documents/Read%20Me.md")
    #expect(urlRequest.value(forHTTPHeaderField: "X-Kosmos-Origin")
      == "kosmos://local")
  }

  /// Fold a synthesized tunnel URL into a `ProxyHTTPRequest`, stamping the
  /// origin header the AVP scheme handler attaches.
  private func makeProxy(forURL url: URL) -> ProxyHTTPRequest? {
    var urlRequest = URLRequest(url: url)
    urlRequest.setValue(
      TunnelScheme.originURL.absoluteString,
      forHTTPHeaderField: TunnelHeaders.origin)
    return ProxyHTTPRequest(requestID: UUID(), request: urlRequest, url: url)
  }

  /// A CSS sub-resource fetch is the same chain, just with a
  /// template path and an asset filename. Locks down that the
  /// scheme/template route survives every layer too — the original
  /// bug only manifested on documents, but the same encoding logic
  /// powers asset URLs that the WebView builds via `<base href>`.
  @Test("a CSS asset under /template/<id>/ round-trips correctly")
  func templateAssetWithSpace() throws {
    let tunnelURL = URL(
      string: "kosmos://local/template/galley.default/style%20one.css")!

    let proxy = try #require(makeProxy(forURL: tunnelURL))
    #expect(proxy.path == "/template/galley.default/style one.css")

    let base = URL(string: "http://127.0.0.1:54775")!
    let urlRequest = try #require(proxy.urlRequest(base: base))
    #expect(urlRequest.url?.absoluteString
      == "http://127.0.0.1:54775/template/galley.default/style%20one.css")
  }
}
