import Foundation
import Testing
import KosmosAppKit
import KosmosCore
import KosmosHTTPTunnel
@testable import GalleyCoreKit

private struct FakeRenderer: MarkdownRenderer {
  func render(_ source: String, baseURL: URL) async throws -> String {
    "<p>BODY</p>"
  }
}

@Suite("InProcessTunnelBackend")
struct InProcessTunnelBackendTests {
  private func tempFile(ext: String, contents: Data) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("itb-test")
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("doc.\(ext)")
    try contents.write(to: url)
    return url
  }

  /// Build the request exactly as the AVP scheme handler would: a
  /// `kosmos://local` URL carrying `path`, folded into a `ProxyHTTPRequest`
  /// via the public initializer (which decodes the path into `.path`).
  private func proxyRequest(path: String) throws -> ProxyHTTPRequest {
    var components = URLComponents()
    components.scheme = "kosmos"
    components.host = "local"
    components.path = path
    let url = try #require(components.url)
    var urlRequest = URLRequest(url: url)
    urlRequest.setValue(
      "kosmos://local", forHTTPHeaderField: TunnelHeaders.origin)
    return try #require(
      ProxyHTTPRequest(requestID: UUID(), request: urlRequest, url: url))
  }

  @MainActor
  private func run(
    _ backend: InProcessTunnelBackend, path: String
  ) async throws -> (status: Int?, headers: [String: String], body: Data) {
    let request = try proxyRequest(path: path)
    var status: Int?
    var headers: [String: String] = [:]
    var body = Data()
    for try await event in backend.resolve(request) {
      switch event {
      case .head(let s, let h): status = s; headers = h
      case .body(let d): body.append(d)
      }
    }
    return (status, headers, body)
  }

  private func makeBackend() -> InProcessTunnelBackend {
    InProcessTunnelBackend(
      service: PreviewRequestService(
        selectedTemplate: { .default },
        renderer: { FakeRenderer() }),
      watcher: DocumentWatcher())
  }

  @MainActor
  @Test("markdown renders to HTML with the live-reload script injected")
  func rendersMarkdown() async throws {
    let url = try tempFile(ext: "md", contents: Data("# Hi".utf8))
    let result = try await run(makeBackend(), path: "/preview" + url.path)
    #expect(result.status == 200)
    let html = String(decoding: result.body, as: UTF8.self)
    #expect(html.contains("<p>BODY</p>"))
    #expect(html.contains("EventSource"))   // reload script injected
    let contentType = result.headers.first {
      $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
    }?.value ?? ""
    #expect(contentType.lowercased().contains("text/html"))
  }

  @MainActor
  @Test("a sibling asset is served as raw bytes")
  func servesAsset() async throws {
    let bytes = Data([9, 8, 7, 6, 5, 4])
    let url = try tempFile(ext: "css", contents: bytes)
    let result = try await run(makeBackend(), path: "/preview" + url.path)
    #expect(result.status == 200)
    #expect(result.body == bytes)
  }
}
