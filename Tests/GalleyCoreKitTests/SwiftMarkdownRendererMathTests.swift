//
//  SwiftMarkdownRendererMathTests.swift
//  Galley
//
//  End-to-end: Markdown with `$…$` spans goes through the built-in
//  renderer and comes out as HTML carrying MathML, with Markdown syntax
//  inside the math protected from the parser and Markdown outside it
//  rendered normally.
//

import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("SwiftMarkdownRenderer math")
struct SwiftMarkdownRendererMathTests {
  private let baseURL = URL(fileURLWithPath: "/tmp/doc.md")

  @Test("Inline TeX becomes MathML and surrounding Markdown still renders")
  func inlineMath() async throws {
    let renderer = SwiftMarkdownRenderer()

    let html = try await renderer.render(
      "Let $a_1 * b_2$ and *em*.", baseURL: baseURL)

    #expect(html.contains("<span class=\"math inline\"><math"))
    #expect(html.contains("<em>em</em>"))
    #expect(html.contains("<msub><mi>a</mi><mn"))
    #expect(!html.contains("<em>b</em>"))
    #expect(!html.contains("$"))
  }

  @Test("Display TeX on its own lines becomes a block")
  func displayMath() async throws {
    let renderer = SwiftMarkdownRenderer()
    let source = """
      Intro

      $$
      E = mc^2
      $$

      Outro
      """

    let html = try await renderer.render(source, baseURL: baseURL)

    #expect(html.contains("<div class=\"math display\" data-source-line=\"3\">"))
    #expect(html.contains("display=\"block\""))
    #expect(html.contains("<p data-source-line=\"7\">Outro</p>"))
  }

  @Test("Dollars inside code are left alone")
  func codeIsUntouched() async throws {
    let renderer = SwiftMarkdownRenderer()

    let html = try await renderer.render(
      "Run `echo $HOME` first.", baseURL: baseURL)

    #expect(html.contains("<code>echo $HOME</code>"))
    #expect(!html.contains("<math"))
  }

  @Test("A failing math engine degrades to a marked-up source span")
  func engineFailureFallsBack() async throws {
    let renderer = SwiftMarkdownRenderer(mathRenderer: FailingMathRenderer())

    let html = try await renderer.render("so $a<b$ holds", baseURL: baseURL)

    #expect(html.contains("<span class=\"math error\""))
    #expect(html.contains("$a&lt;b$"))
    #expect(html.contains("title=\"boom\""))
  }

  @Test("Math support can be switched off")
  func disabled() async throws {
    let renderer = SwiftMarkdownRenderer(mathRenderer: nil)

    let html = try await renderer.render("so $x$ holds", baseURL: baseURL)

    #expect(html.contains("$x$"))
    #expect(!html.contains("<math"))
  }
}

private struct FailingMathRenderer: TeXMathRenderer {
  struct Failure: Error, CustomStringConvertible {
    var description: String { "boom" }
  }

  func render(_ span: MathSpan) async throws -> String {
    throw Failure()
  }
}
