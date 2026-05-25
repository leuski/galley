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
import KosmosHTTPTunnel
import Testing
@testable import GalleyCoreKit

@Suite("URLBuilder.buildURLRequest")
struct HTTPTunnelURLBuilderBuildRequestTests {
  private static let loopback =
    URL(string: "http://127.0.0.1:54775")!

  @Test("splices path onto base, preserves method, drops Host header")
  func basicGet() throws {
    let request = ProxyHTTPRequest(
      method: "GET",
      urlPath: "/preview/Users/x/Documents/foo.md",
      headers: ["Accept": "text/html", "Host": "ignored:9999"])
    let urlRequest = try #require(URLBuilder.buildURLRequest(
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
    let urlRequest = try #require(URLBuilder.buildURLRequest(
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
    let urlRequest = try #require(URLBuilder.buildURLRequest(
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
    let urlRequest = try #require(URLBuilder.buildURLRequest(
      base: Self.loopback, request: request))
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.httpBody == Data(#"{"hello":"world"}"#.utf8))
    #expect(urlRequest.value(forHTTPHeaderField: "Content-Type")
      == "application/json")
  }

  @Test("rejects urlPath that doesn't start with /")
  func rejectsRelativePath() {
    let request = ProxyHTTPRequest(method: "GET", urlPath: "preview/foo")
    #expect(URLBuilder.buildURLRequest(
      base: Self.loopback, request: request) == nil)
  }

  @Test("Host header drop is case-insensitive")
  func hostCaseInsensitive() throws {
    let request = ProxyHTTPRequest(
      method: "GET",
      urlPath: "/",
      headers: ["host": "leak.example", "HOST": "also-leak"])
    let urlRequest = try #require(URLBuilder.buildURLRequest(
      base: Self.loopback, request: request))
    #expect(urlRequest.value(forHTTPHeaderField: "Host") == nil)
    #expect(urlRequest.value(forHTTPHeaderField: "host") == nil)
  }
}

@Suite("URLBuilder.extractHeaders")
struct HTTPTunnelURLBuilderExtractHeadersTests {
  @Test("nil response yields empty headers")
  func nilResponse() {
    #expect(URLBuilder.extractHeaders(from: nil).isEmpty)
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
    let headers = URLBuilder.extractHeaders(from: response)
    #expect(headers["Content-Type"] == "text/html; charset=utf-8")
    #expect(headers["Content-Length"] == "29970")
    #expect(headers["X-Custom"] == "value")
  }
}

@Suite("URLBuilder.chunks")
struct HTTPTunnelURLBuilderChunksTests {
  private static let requestID = UUID()

  @Test("empty body emits a single empty final chunk")
  func empty() {
    let chunks = URLBuilder.chunks(
      of: Data(), requestID: Self.requestID, chunkSize: 64)
    #expect(chunks.count == 1)
    #expect(chunks[0].bytes.isEmpty)
    #expect(chunks[0].sequence == 0)
    #expect(chunks[0].isFinal)
  }

  @Test("body smaller than chunkSize emits one final chunk verbatim")
  func smallerThanChunk() {
    let body = Data(repeating: 0xAB, count: 100)
    let chunks = URLBuilder.chunks(
      of: body, requestID: Self.requestID, chunkSize: 1024)
    #expect(chunks.count == 1)
    #expect(chunks[0].bytes == body)
    #expect(chunks[0].sequence == 0)
    #expect(chunks[0].isFinal)
  }

  @Test("body equal to chunkSize emits one final chunk")
  func equalToChunk() {
    let body = Data(repeating: 0xCD, count: 64)
    let chunks = URLBuilder.chunks(
      of: body, requestID: Self.requestID, chunkSize: 64)
    #expect(chunks.count == 1)
    #expect(chunks[0].bytes.count == 64)
    #expect(chunks[0].isFinal)
  }

  @Test("body larger than chunkSize splits with correct sequence + isFinal")
  func largerThanChunk() {
    let body = Data((0..<200).map { UInt8($0 % 256) })
    let chunks = URLBuilder.chunks(
      of: body, requestID: Self.requestID, chunkSize: 64)
    #expect(chunks.count == 4)
    #expect(chunks.map(\.bytes.count) == [64, 64, 64, 8])
    #expect(chunks.map(\.sequence) == [0, 1, 2, 3])
    #expect(chunks.map(\.isFinal) == [false, false, false, true])
    // Reassembled bytes equal the original buffer.
    let reassembled = chunks.reduce(into: Data()) { $0.append($1.bytes) }
    #expect(reassembled == body)
  }

  @Test("every chunk carries the same requestID")
  func sameRequestID() {
    let body = Data(repeating: 0x11, count: 256)
    let chunks = URLBuilder.chunks(
      of: body, requestID: Self.requestID, chunkSize: 64)
    #expect(chunks.allSatisfy { $0.requestID == Self.requestID })
  }
}

@Suite("URLBuilder.isEventStream")
struct HTTPTunnelURLBuilderIsEventStreamTests {
  @Test("text/event-stream → streaming")
  func bare() {
    #expect(URLBuilder.isEventStream(
      ["Content-Type": "text/event-stream"]))
  }

  @Test("text/event-stream with charset parameter → streaming")
  func withParameter() {
    #expect(URLBuilder.isEventStream(
      ["Content-Type": "text/event-stream; charset=utf-8"]))
  }

  @Test("Content-Type header name is case-insensitive")
  func nameCaseInsensitive() {
    #expect(URLBuilder.isEventStream(
      ["content-type": "text/event-stream"]))
    #expect(URLBuilder.isEventStream(
      ["CONTENT-TYPE": "text/event-stream"]))
  }

  @Test("Content-Type value is case-insensitive")
  func valueCaseInsensitive() {
    #expect(URLBuilder.isEventStream(
      ["Content-Type": "Text/Event-Stream"]))
  }

  @Test("text/html → not streaming")
  func textHTML() {
    #expect(!URLBuilder.isEventStream(
      ["Content-Type": "text/html; charset=utf-8"]))
  }

  @Test("image/png → not streaming")
  func imagePNG() {
    #expect(!URLBuilder.isEventStream(
      ["Content-Type": "image/png"]))
  }

  @Test("missing Content-Type → not streaming")
  func missing() {
    #expect(!URLBuilder.isEventStream([:]))
    #expect(!URLBuilder.isEventStream(
      ["Other-Header": "value"]))
  }
}
