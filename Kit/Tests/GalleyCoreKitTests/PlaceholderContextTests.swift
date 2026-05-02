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
}
