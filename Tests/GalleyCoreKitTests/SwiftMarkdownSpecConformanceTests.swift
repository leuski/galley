import Foundation
import Testing
@testable import GalleyCoreKit

// Spot-checks against examples and rules from the CommonMark spec
// (https://spec.commonmark.org/0.31.2/) plus the GFM extensions that
// swift-markdown supports (tables, strikethrough, task list checkboxes).
//
// Each assertion targets a normative aspect of the rendered HTML
// (tag, attribute, escaping, whitespace inside <code>) rather than
// byte-for-byte cmark-gfm output, since CommonMark explicitly does
// not require byte-identical rendering. Whitespace between block
// elements is left to the implementation.
@Suite("SwiftMarkdownRenderer / CommonMark conformance")
struct SwiftMarkdownSpecConformanceTests {
  private let baseURL = URL(fileURLWithPath: "/tmp/doc.md")

  private func render(_ source: String) async throws -> String {
    let renderer = SwiftMarkdownRenderer()
    return try await renderer.render(source, baseURL: baseURL)
  }

  // MARK: - Headings

  @Test("ATX headings render at the correct level")
  func atxHeadingsAreLevelClamped() async throws {
    let html = try await render(
      "# h1\n## h2\n### h3\n#### h4\n##### h5\n###### h6\n")
    #expect(html.contains(">h1</h1>"))
    #expect(html.contains(">h2</h2>"))
    #expect(html.contains(">h3</h3>"))
    #expect(html.contains(">h4</h4>"))
    #expect(html.contains(">h5</h5>"))
    #expect(html.contains(">h6</h6>"))
  }

  @Test("Setext headings render as h1 / h2")
  func setextHeadings() async throws {
    let html = try await render("Foo\n===\n\nBar\n---\n")
    #expect(html.contains(">Foo</h1>"))
    #expect(html.contains(">Bar</h2>"))
  }

  // MARK: - Code blocks

  @Test("Indented code block content ends with a newline inside <code>")
  func indentedCodeBlockTrailingNewline() async throws {
    let html = try await render("    a simple\n      indented code\n")
    // Per CommonMark, code block content always ends with a newline
    // inside <code>...</code>. (Spec example 92.)
    #expect(html.contains("indented code\n</code></pre>"))
  }

  @Test("Fenced code block escapes <, >, & inside <code>")
  func fencedCodeBlockEscapes() async throws {
    let html = try await render("```\n<a> & <b>\n```\n")
    #expect(html.contains("<pre"))
    #expect(html.contains("&lt;a&gt; &amp; &lt;b&gt;"))
    #expect(!html.contains("<a>"))
  }

  @Test("Fenced code block info string becomes language- class")
  func fencedCodeBlockLanguageClass() async throws {
    let html = try await render("```swift\nlet x = 1\n```\n")
    #expect(html.contains("<code class=\"language-swift\">"))
  }

  @Test("Fenced code block without info string omits the class attribute")
  func fencedCodeBlockNoLanguage() async throws {
    let html = try await render("```\nplain\n```\n")
    #expect(html.contains("<pre"))
    // No class= attribute at all when there is no info string.
    #expect(!html.contains("class=\"language-"))
  }

  // MARK: - Inline code

  @Test("Inline code escapes HTML")
  func inlineCodeEscapesHTML() async throws {
    let html = try await render("`<a> & <b>`\n")
    #expect(html.contains("<code>&lt;a&gt; &amp; &lt;b&gt;</code>"))
  }

  // MARK: - Emphasis / strong / strikethrough

  @Test("Emphasis and strong render as <em> / <strong>")
  func emphasisAndStrong() async throws {
    let html = try await render("*em* and **strong**\n")
    #expect(html.contains("<em>em</em>"))
    #expect(html.contains("<strong>strong</strong>"))
  }

  @Test("Strikethrough renders as <del>")
  func strikethroughRendersAsDel() async throws {
    let html = try await render("~~gone~~\n")
    #expect(html.contains("<del>gone</del>"))
  }

  // MARK: - Links and images

  @Test("Link emits href and optional title, body inside <a>")
  func linkWithTitle() async throws {
    let html = try await render("[hi](/url \"a title\")\n")
    #expect(html.contains(
      "<a href=\"/url\" title=\"a title\">hi</a>"))
  }

  @Test("Empty link destination still emits href=\"\"")
  func emptyLinkDestination() async throws {
    let html = try await render("[no dest]()\n")
    #expect(html.contains("<a href=\"\">no dest</a>"))
  }

  @Test("Image emits src/alt, alt is plain text only")
  func imageAltIsPlainText() async throws {
    let html = try await render("![*alt* text](/img.png \"t\")\n")
    // alt is plain text — formatting is stripped per CommonMark.
    #expect(html.contains(
      "<img src=\"/img.png\" alt=\"alt text\" title=\"t\">"))
  }

  @Test("Image inside a link nests correctly")
  func imageInsideLink() async throws {
    let html = try await render("[![alt](/i.png)](/u)\n")
    #expect(html.contains("<a href=\"/u\">"))
    #expect(html.contains("<img src=\"/i.png\""))
    #expect(html.contains("</a>"))
  }

  @Test("Reference link resolves through the link reference definition")
  func referenceLinkResolves() async throws {
    let source = "[label][id]\n\n[id]: /target \"t\"\n"
    let html = try await render(source)
    #expect(html.contains("<a href=\"/target\" title=\"t\">label</a>"))
  }

  @Test("Reference link definition does not appear in output")
  func referenceLinkDefinitionIsNotRendered() async throws {
    let html = try await render("[a][id]\n\n[id]: /x\n")
    #expect(!html.contains("[id]:"))
    #expect(!html.contains("/x\n"))
  }

  @Test("Autolink renders the URL as both href and text")
  func autolink() async throws {
    let html = try await render("<https://example.com>\n")
    #expect(html.contains(
      "<a href=\"https://example.com\">https://example.com</a>"))
  }

  // MARK: - Line breaks

  @Test("Hard line break renders as <br>")
  func hardLineBreak() async throws {
    let html = try await render("foo  \nbar\n")
    #expect(html.contains("foo<br>"))
  }

  @Test("Soft break renders as a newline (browser-equivalent space)")
  func softBreak() async throws {
    let html = try await render("foo\nbar\n")
    #expect(html.contains("<p"))
    #expect(html.contains("foo\nbar"))
  }

  // MARK: - Thematic break

  @Test("Thematic break renders as <hr>")
  func thematicBreak() async throws {
    let html = try await render("---\n")
    #expect(html.contains("<hr"))
  }

  // MARK: - Block quotes

  @Test("Block quote wraps inner blocks")
  func blockQuoteWrapsContent() async throws {
    let html = try await render("> hello\n> world\n")
    #expect(html.contains("<blockquote"))
    #expect(html.contains("<p"))
    #expect(html.contains("hello\nworld"))
    #expect(html.contains("</blockquote>"))
  }

  // MARK: - Lists

  @Test("Ordered list emits start attribute when not 1")
  func orderedListStart() async throws {
    let html = try await render("3. a\n4. b\n")
    #expect(html.contains("<ol start=\"3\""))
  }

  @Test("Ordered list omits start attribute when starting at 1")
  func orderedListStartOne() async throws {
    let html = try await render("1. a\n2. b\n")
    #expect(html.contains("<ol"))
    #expect(!html.contains("start=\""))
  }

  @Test("Tight list with nested loose sublist renders correctly")
  func nestedListTightOuterLooseInner() async throws {
    let source = """
      - outer one
      - outer two
        - inner a

        - inner b
      """
    let html = try await render(source)
    // Outer is tight: items have no <p>.
    #expect(html.contains("<li data-source-line=\"1\">outer one"))
    // Inner has a blank line between items: it is loose, so its
    // items keep their <p> wrappers.
    #expect(html.contains("<p"))
    #expect(html.contains("inner a"))
    #expect(html.contains("inner b"))
  }

  @Test("Task list checkbox renders disabled <input>")
  func taskListCheckbox() async throws {
    let html = try await render("- [x] done\n- [ ] todo\n")
    #expect(html.contains("type=\"checkbox\""))
    #expect(html.contains("disabled"))
    #expect(html.contains("checked"))
  }

  // MARK: - Raw HTML

  @Test("HTML block passes through unchanged")
  func htmlBlockPassesThrough() async throws {
    let html = try await render("<div class=\"x\">raw</div>\n")
    #expect(html.contains("<div class=\"x\">raw</div>"))
  }

  @Test("Inline HTML passes through unchanged")
  func inlineHTMLPassesThrough() async throws {
    let html = try await render("a <span>b</span> c\n")
    #expect(html.contains("<span>b</span>"))
  }

  // MARK: - Escapes

  @Test("Backslash escapes are unescaped before rendering")
  func backslashEscape() async throws {
    let html = try await render("\\*not emphasis\\*\n")
    #expect(html.contains("*not emphasis*"))
    #expect(!html.contains("<em>"))
  }

  @Test("Plain text with HTML metacharacters is escaped")
  func plainTextHTMLEscaping() async throws {
    let html = try await render("a < b & c > d\n")
    #expect(html.contains("a &lt; b &amp; c &gt; d"))
  }

  // MARK: - Tables (GFM)

  @Test("GFM table emits thead/tbody and column alignment")
  func gfmTable() async throws {
    let source = """
      | A | B |
      |:--|--:|
      | 1 | 2 |
      """
    let html = try await render(source)
    #expect(html.contains("<table"))
    #expect(html.contains("<thead>"))
    #expect(html.contains("<tbody>"))
    #expect(html.contains("text-align: left"))
    #expect(html.contains("text-align: right"))
    #expect(html.contains("<td"))
    #expect(html.contains("</table>"))
  }
}
