import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("SwiftMarkdownRenderer")
struct SwiftMarkdownRendererTests {
  private let baseURL = URL(fileURLWithPath: "/tmp/doc.md")

  @Test("Renderer tags block elements with source line")
  func tagsBlocks() async throws {
    let renderer = SwiftMarkdownRenderer()
    let source = """
      # Heading

      First paragraph.

      Second paragraph.
      """
    let html = try await renderer.render(source, baseURL: baseURL)
    #expect(html.contains("<h1 data-source-line=\"1\">"))
    #expect(html.contains("<p data-source-line=\"3\">"))
    #expect(html.contains("<p data-source-line=\"5\">"))
  }

  @Test("Renderer tags lists, code, and quotes")
  func tagsBlockLikeStructures() async throws {
    let renderer = SwiftMarkdownRenderer()
    let source = """
      - item one
      - item two

      > quote on line four

      ```
      code line six
      ```
      """
    let html = try await renderer.render(source, baseURL: baseURL)
    #expect(html.contains("<ul data-source-line=\"1\">"))
    #expect(html.contains("<blockquote data-source-line=\"4\">"))
    #expect(html.contains("<pre data-source-line=\"6\">"))
  }

  @Test("Tight list items are not wrapped in <p>")
  func tightListItemsAreNotWrappedInParagraphs() async throws {
    let renderer = SwiftMarkdownRenderer()
    let source = """
      - item one
      - item two
      - item three
      """
    let html = try await renderer.render(source, baseURL: baseURL)
    #expect(!html.contains("<p"))
    #expect(html.contains("<li data-source-line=\"1\">item one</li>"))
    #expect(html.contains("<li data-source-line=\"2\">item two</li>"))
  }

  @Test("Loose list items keep <p> wrappers")
  func looseListItemsKeepParagraphs() async throws {
    let renderer = SwiftMarkdownRenderer()
    let source = """
      - item one

      - item two

      - item three
      """
    let html = try await renderer.render(source, baseURL: baseURL)
    #expect(html.contains("<p data-source-line=\"1\">item one</p>"))
    #expect(html.contains("<p data-source-line=\"3\">item two</p>"))
  }
}
