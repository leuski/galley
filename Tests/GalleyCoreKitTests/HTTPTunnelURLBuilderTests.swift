//
//  HTTPTunnelURLBuilderTests.swift
//
//  Pin the pure URL/header helpers the Galley HTTP tunnel uses on
//  both ends. The Mac responder builds a `URLRequest` from an inbound
//  `ProxyHTTPRequest` and extracts headers from `HTTPURLResponse`;
//  these tests pin both transforms without touching `URLSession` or
//  the Kosmos transport.
//

import Foundation
import KosmosCore
import Testing
@testable import GalleyCoreKit

@Suite("HTTPTunnelURLBuilder.buildURLRequest")
struct HTTPTunnelURLBuilderBuildRequestTests {
  private static let loopback =
    URL(string: "http://127.0.0.1:54775")!

  @Test("splices path onto base, preserves method, drops Host header")
  func basicGet() throws {
    let request = ProxyHTTPRequest(
      method: "GET",
      urlPath: "/preview/Users/x/Documents/foo.md",
      headers: ["Accept": "text/html", "Host": "ignored:9999"])
    let urlRequest = try #require(HTTPTunnelURLBuilder.buildURLRequest(
      base: Self.loopback, request: request))
    #expect(urlRequest.url?.absoluteString
      == "http://127.0.0.1:54775/preview/Users/x/Documents/foo.md")
    #expect(urlRequest.httpMethod == "GET")
    #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "text/html")
    #expect(urlRequest.value(forHTTPHeaderField: "Host") == nil)
  }

  @Test("preserves query string verbatim")
  func preservesQuery() throws {
    let request = ProxyHTTPRequest(
      method: "GET",
      urlPath: "/events/foo.md?token=abc%20def&line=42")
    let urlRequest = try #require(HTTPTunnelURLBuilder.buildURLRequest(
      base: Self.loopback, request: request))
    let url = try #require(urlRequest.url)
    #expect(url.query == "token=abc%20def&line=42")
    #expect(url.path == "/events/foo.md")
  }

  @Test("preserves percent-encoded path segments")
  func preservesEncodedPath() throws {
    // Galley's preview path includes filesystem segments that may
    // contain spaces/unicode. The tunnel assumes the wire path is
    // already percent-encoded; the builder must not re-encode.
    let request = ProxyHTTPRequest(
      method: "GET",
      urlPath: "/preview/Users/x/Read%20Me.md")
    let urlRequest = try #require(HTTPTunnelURLBuilder.buildURLRequest(
      base: Self.loopback, request: request))
    #expect(urlRequest.url?.absoluteString
      == "http://127.0.0.1:54775/preview/Users/x/Read%20Me.md")
  }

  @Test("attaches body for non-GET methods")
  func body() throws {
    let request = ProxyHTTPRequest(
      method: "POST",
      urlPath: "/some/endpoint",
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"hello":"world"}"#.utf8))
    let urlRequest = try #require(HTTPTunnelURLBuilder.buildURLRequest(
      base: Self.loopback, request: request))
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.httpBody == Data(#"{"hello":"world"}"#.utf8))
    #expect(urlRequest.value(forHTTPHeaderField: "Content-Type")
      == "application/json")
  }

  @Test("rejects urlPath that doesn't start with /")
  func rejectsRelativePath() {
    let request = ProxyHTTPRequest(method: "GET", urlPath: "preview/foo")
    #expect(HTTPTunnelURLBuilder.buildURLRequest(
      base: Self.loopback, request: request) == nil)
  }

  @Test("Host header drop is case-insensitive")
  func hostCaseInsensitive() throws {
    let request = ProxyHTTPRequest(
      method: "GET",
      urlPath: "/",
      headers: ["host": "leak.example", "HOST": "also-leak"])
    let urlRequest = try #require(HTTPTunnelURLBuilder.buildURLRequest(
      base: Self.loopback, request: request))
    #expect(urlRequest.value(forHTTPHeaderField: "Host") == nil)
    #expect(urlRequest.value(forHTTPHeaderField: "host") == nil)
  }
}

@Suite("HTTPTunnelURLBuilder.extractHeaders")
struct HTTPTunnelURLBuilderExtractHeadersTests {
  @Test("nil response yields empty headers")
  func nilResponse() {
    #expect(HTTPTunnelURLBuilder.extractHeaders(from: nil).isEmpty)
  }

  @Test("string-keyed headers round-trip")
  func stringHeaders() throws {
    let url = URL(string: "http://127.0.0.1/")!
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": "text/html; charset=utf-8",
        "Content-Length": "29970",
        "X-Custom": "value"
      ])
    let headers = HTTPTunnelURLBuilder.extractHeaders(from: response)
    #expect(headers["Content-Type"] == "text/html; charset=utf-8")
    #expect(headers["Content-Length"] == "29970")
    #expect(headers["X-Custom"] == "value")
  }
}
