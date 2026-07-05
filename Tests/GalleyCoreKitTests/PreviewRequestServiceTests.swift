import Foundation
import Testing
@testable import GalleyCoreKit

private struct FakeRenderer: MarkdownRenderer {
  let body: String
  func render(_ source: String, baseURL: URL) async throws -> String { body }
}

@Suite("PreviewRequestService")
struct PreviewRequestServiceTests {
  private let origin = URL(string: "x-galley://local")!

  private func service(
    renderer: (any MarkdownRenderer)? = FakeRenderer(body: "<p>BODY</p>")
  ) -> PreviewRequestService {
    PreviewRequestService(
      selectedTemplate: { .bundledDefault },
      renderer: { renderer })
  }

  /// Write `contents` to a temp file with `ext`; returns its URL.
  private func tempFile(ext: String, contents: Data) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("prs-\(UInt64(abs(ext.hashValue)))-test")
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("doc.\(ext)")
    try contents.write(to: url)
    return url
  }

  @Test("renders a markdown document into HTML")
  func rendersMarkdown() async throws {
    let url = try tempFile(ext: "md", contents: Data("# Hi".utf8))
    let response = await service().respond(
      path: "/preview" + url.path, origin: origin)
    guard case .html(let html, let documentURL) = response else {
      Issue.record("expected .html, got \(response)"); return
    }
    #expect(documentURL.path == url.path)
    #expect(html.contains("<p>BODY</p>"))
  }

  @Test("serves a sibling asset as bytes with no-store")
  func servesAsset() async throws {
    let bytes = Data([1, 2, 3, 4, 5])
    let url = try tempFile(ext: "css", contents: bytes)
    let response = await service().respond(
      path: "/preview" + url.path, origin: origin)
    guard case .bytes(let resolved) = response else {
      Issue.record("expected .bytes, got \(response)"); return
    }
    #expect(resolved.data == bytes)
    #expect(resolved.cache == .noStore)
  }

  @Test("markdown path with no renderer is a structured failure")
  func noProcessor() async throws {
    let url = try tempFile(ext: "md", contents: Data("# Hi".utf8))
    let response = await service(renderer: nil).respond(
      path: "/preview" + url.path, origin: origin)
    guard case .failure(.noProcessor) = response else {
      Issue.record("expected .failure(.noProcessor), got \(response)"); return
    }
  }

  @Test("unsupported extension is not found")
  func unsupportedExtension() async throws {
    let url = try tempFile(ext: "xyz", contents: Data())
    let response = await service().respond(
      path: "/preview" + url.path, origin: origin)
    guard case .notFound = response else {
      Issue.record("expected .notFound, got \(response)"); return
    }
  }

  @Test("events route returns the document URL for a markdown path")
  func eventsForMarkdown() async throws {
    let response = await service().respond(
      path: "/events/Users/x/doc.md", origin: origin)
    guard case .events(let documentURL) = response else {
      Issue.record("expected .events, got \(response)"); return
    }
    #expect(documentURL.path == "/Users/x/doc.md")
  }

  @Test("events route rejects a non-markdown path")
  func eventsRejectsNonMarkdown() async throws {
    let response = await service().respond(
      path: "/events/Users/x/style.css", origin: origin)
    guard case .badRequest = response else {
      Issue.record("expected .badRequest, got \(response)"); return
    }
  }

  @Test("index path returns ok")
  func indexOk() async throws {
    let response = await service().respond(path: "/", origin: origin)
    guard case .plainText = response else {
      Issue.record("expected .plainText"); return
    }
  }

  @Test("unknown path is not found")
  func unknownNotFound() async throws {
    guard case .notFound = await service().respond(
      path: "/nope", origin: origin)
    else {
      Issue.record("expected .notFound"); return
    }
  }
}
