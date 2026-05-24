#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

@Suite("ReloadScriptInjection")
struct ReloadScriptInjectionTests {
  private let documentURL = URL(fileURLWithPath: "/tmp/note.md")
  private let nonce = "TEST-NONCE"

  @Test("Script is inserted before </body> when present")
  func insertedBeforeBody() {
    let html = "<html><body><h1>Hi</h1></body></html>"
    let out = Routes.injectReloadScript(
      into: html, documentURL: documentURL, nonce: nonce)
    #expect(out.contains("<script nonce=\"TEST-NONCE\">"))
    let scriptRange = out.range(of: "<script")
    let bodyRange = out.range(of: "</body>")
    #expect(scriptRange != nil && bodyRange != nil)
    #expect((scriptRange?.lowerBound ?? out.endIndex)
            < (bodyRange?.lowerBound ?? out.startIndex))
  }

  @Test("</body> match is case-insensitive")
  func caseInsensitiveBodyMatch() {
    let html = "<HTML><BODY>x</BODY></HTML>"
    let out = Routes.injectReloadScript(
      into: html, documentURL: documentURL, nonce: nonce)
    #expect(out.contains("<script nonce=\"TEST-NONCE\">"))
    // Original closing tag is preserved, replaced once with script + tag.
    #expect(out.contains("</BODY></HTML>") || out.contains("</body></HTML>"))
  }

  @Test("Script appended at end when </body> is missing")
  func appendedWhenNoBody() {
    let html = "<h1>Naked fragment</h1>"
    let out = Routes.injectReloadScript(
      into: html, documentURL: documentURL, nonce: nonce)
    #expect(out.hasSuffix("</script>"))
    #expect(out.contains("<script nonce=\"TEST-NONCE\">"))
  }

  @Test("EventSource path is the percent-encoded /events/<doc-path>")
  func eventSourcePath() {
    let url = URL(fileURLWithPath: "/tmp/foo bar.md")
    let out = Routes.injectReloadScript(
      into: "<body></body>", documentURL: url, nonce: nonce)
    #expect(out.contains("new EventSource('/events/tmp/foo%20bar.md')"))
  }

  @Test("Nonce flows verbatim into the script tag attribute")
  func nonceWiredThrough() {
    let out = Routes.injectReloadScript(
      into: "<body></body>",
      documentURL: documentURL,
      nonce: "abc123==")
    #expect(out.contains("<script nonce=\"abc123==\">"))
  }

  @Test("reload event listener triggers location.reload")
  func reloadListener() {
    let out = Routes.injectReloadScript(
      into: "<body></body>", documentURL: documentURL, nonce: nonce)
    #expect(out.contains("addEventListener('reload'"))
    #expect(out.contains("location.reload()"))
  }
}
#endif
