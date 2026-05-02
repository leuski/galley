import Foundation
import Testing

@testable import GalleyCoreKit
internal import ALFoundation

@Suite("UserTemplate.Rewriter")
struct UserTemplateRewriterTests {
  private let origin: URL = "http://127.0.0.1:8089"

  @Test("Relative <link href> is routed through /template/<id>/")
  func relativeLink() {
    let rewriter = UserTemplate.Rewriter(id: "myth", origin: origin)
    let html = #"<link rel="stylesheet" href="style.css">"#
    let out = rewriter.rewriteAssets(in: html)
    #expect(out.contains(
      "http://127.0.0.1:8089/template/myth/style.css"))
  }

  @Test("Absolute filesystem href is routed through /preview")
  func absoluteHref() {
    let rewriter = UserTemplate.Rewriter(id: "myth", origin: origin)
    let html = #"<img src="/Users/foo/pic.png">"#
    let out = rewriter.rewriteAssets(in: html)
    #expect(out.contains(
      "http://127.0.0.1:8089/preview/Users/foo/pic.png"))
  }

  @Test("BBEdit placeholder #BASE# is left untouched")
  func bbeditPlaceholder() {
    let rewriter = UserTemplate.Rewriter(id: "myth", origin: origin)
    let html = ##"<base href="#BASE#">"##
    let out = rewriter.rewriteAssets(in: html)
    #expect(out == html)
  }

  @Test("Absolute URL with scheme is left untouched")
  func absoluteScheme() {
    let rewriter = UserTemplate.Rewriter(id: "myth", origin: origin)
    let html = #"<script src="https://cdn.example.com/lib.js"></script>"#
    let out = rewriter.rewriteAssets(in: html)
    #expect(out == html)
  }

  @Test("CSS url(...) inside <style> is rewritten")
  func cssUrl() {
    let rewriter = UserTemplate.Rewriter(id: "myth", origin: origin)
    let html = "<style>body { background: url(bg.png); }</style>"
    let out = rewriter.rewriteAssets(in: html)
    #expect(out.contains(
      "url(http://127.0.0.1:8089/template/myth/bg.png)"))
  }

  @Test("Template id with space gets percent-encoded in prefix")
  func encodedTemplateID() {
    let rewriter = UserTemplate.Rewriter(id: "My Theme", origin: origin)
    let html = #"<link href="style.css">"#
    let out = rewriter.rewriteAssets(in: html)
    #expect(out.contains(
      "http://127.0.0.1:8089/template/My%20Theme/style.css"))
  }
}
