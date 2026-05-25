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
//    HTTPTunnelURLBuilderTests        → ProxyHTTPRequest → URLRequest (Mac)
//    TemplateOriginURLTests           → X-Galley-Origin → base href
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
    let tunnelURL = try #require(
      KosmosTunnelScheme.previewURL(forFile: documentPath))
    #expect(tunnelURL.absoluteString
      == "galley://local/preview/Users/x/Documents/Read%20Me.md")

    // Layer 2: simulated AVP scheme handler — wire `urlPath` is
    // `URLComponents.percentEncodedPath` verbatim.
    let components = try #require(URLComponents(
      url: tunnelURL, resolvingAgainstBaseURL: false))
    let wireURLPath = components.percentEncodedPath
    #expect(wireURLPath == "/preview/Users/x/Documents/Read%20Me.md")

    // Layer 3: Mac splices `urlPath` onto the loopback base.
    let base = URL(string: "http://127.0.0.1:54775")!
    let proxy = ProxyHTTPRequest(
      method: "GET",
      urlPath: wireURLPath,
      headers: [
        "X-Galley-Origin": KosmosTunnelScheme.originURL.absoluteString
      ])
    let urlRequest = try #require(
      HTTPTunnelURLBuilder.buildURLRequest(base: base, request: proxy))
    #expect(urlRequest.url?.absoluteString
      == "http://127.0.0.1:54775/preview/Users/x/Documents/Read%20Me.md")
    #expect(urlRequest.value(forHTTPHeaderField: "X-Galley-Origin")
      == "galley://local")
  }

  /// A CSS sub-resource fetch is the same chain, just with a
  /// template path and an asset filename. Locks down that the
  /// scheme/template route survives every layer too — the original
  /// bug only manifested on documents, but the same encoding logic
  /// powers asset URLs that the WebView builds via `<base href>`.
  @Test("a CSS asset under /template/<id>/ round-trips correctly")
  func templateAssetWithSpace() throws {
    let tunnelURL = URL(
      string: "galley://local/template/galley.default/style%20one.css")!

    let components = try #require(URLComponents(
      url: tunnelURL, resolvingAgainstBaseURL: false))
    let wireURLPath = components.percentEncodedPath
    #expect(wireURLPath == "/template/galley.default/style%20one.css")

    let base = URL(string: "http://127.0.0.1:54775")!
    let proxy = ProxyHTTPRequest(
      method: "GET",
      urlPath: wireURLPath,
      headers: [
        "X-Galley-Origin": KosmosTunnelScheme.originURL.absoluteString
      ])
    let urlRequest = try #require(
      HTTPTunnelURLBuilder.buildURLRequest(base: base, request: proxy))
    #expect(urlRequest.url?.absoluteString
      == "http://127.0.0.1:54775/template/galley.default/style%20one.css")
  }
}
