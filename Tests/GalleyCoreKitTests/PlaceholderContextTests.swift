import Foundation
import Testing

import GalleyCoreKit
internal import ALFoundation

@Suite("PlaceholderContext.substitute")
struct PlaceholderContextTests {
  private let origin: URL = "http://127.0.0.1:8089"

  @Test("#BASE# resolves to /preview/<docDir>/ with encoded spaces")
  func baseHref() {
    let context = PlaceholderContext(
      documentContent: "",
      documentURL: URL(fileURLWithPath: "/Users/foo/My Notes/post.md"),
      origin: origin)
    let out = context.substitute(into: "<base href=\"#BASE#\">")
    #expect(out
      == "<base href=\"http://127.0.0.1:8089/preview/Users/foo/My%20Notes/\">")
  }

  @Test("#TITLE# uses the document basename without extension")
  func title() {
    let context = PlaceholderContext(
      documentContent: "",
      documentURL: URL(fileURLWithPath: "/x/Hello World.md"),
      origin: origin)
    let out = context.substitute(into: "<title>#TITLE#</title>")
    #expect(out == "<title>Hello World</title>")
  }

  @Test("#DOCUMENT_CONTENT# inserts the rendered body")
  func documentContent() {
    let context = PlaceholderContext(
      documentContent: "<p>hi</p>",
      documentURL: URL(fileURLWithPath: "/x/a.md"),
      origin: origin)
    let out = context.substitute(into: "<main>#DOCUMENT_CONTENT#</main>")
    #expect(out == "<main><p>hi</p></main>")
  }

  @Test("Placeholders inside body content are not re-substituted")
  func bodyContentNotRescanned() {
    // A user typing a metadata placeholder in their markdown — even in a
    // code span — must see it as literal text, not as the substituted
    // value. This guards against substitution running over the composed
    // template+body string.
    let context = PlaceholderContext(
      documentContent: "<p><code>#TIME#</code> and <code>#TITLE#</code></p>",
      documentURL: URL(fileURLWithPath: "/x/doc.md"),
      origin: origin)
    let out = context.substitute(into: "<main>#DOCUMENT_CONTENT#</main>")
    #expect(out
      == "<main><p><code>#TIME#</code> and <code>#TITLE#</code></p></main>")
  }

  @Test("#DOCUMENT_CONTENT# literal in body content is not re-injected")
  func bodyContentDocumentContentTokenIsLiteral() {
    // If a user writes the literal string "#DOCUMENT_CONTENT#" in their
    // markdown, it should appear as text — not trigger another body
    // injection (which would either be a no-op, recursion, or corruption
    // depending on order).
    let context = PlaceholderContext(
      documentContent: "<p>see #DOCUMENT_CONTENT# token</p>",
      documentURL: URL(fileURLWithPath: "/x/doc.md"),
      origin: origin)
    let out = context.substitute(into: "<main>#DOCUMENT_CONTENT#</main>")
    #expect(out == "<main><p>see #DOCUMENT_CONTENT# token</p></main>")
  }
}
