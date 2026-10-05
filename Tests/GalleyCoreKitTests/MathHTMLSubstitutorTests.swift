//
//  MathHTMLSubstitutorTests.swift
//  Galley
//
//  The substitutor is the post-pass: after swift-markdown has rendered
//  the sentinel-carrying source, each sentinel is swapped for the
//  rendered MathML. A display span that was the whole paragraph must
//  become a block (`<div>`), keeping the paragraph's attributes such as
//  `data-source-line`, because `<div>` inside `<p>` is invalid HTML.
//

import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("MathHTMLSubstitutor")
struct MathHTMLSubstitutorTests {
  private func sentinel(_ index: Int) -> String {
    MathSpanExtractor.sentinel(index: index)
  }

  @Test("Inline sentinel becomes an inline math span")
  func inlineSpan() {
    let html = "<p data-source-line=\"1\">Let \(sentinel(0)) be.</p>"
    let result = MathHTMLSubstitutor.substitute(
      in: html,
      spans: [MathSpan(tex: "x", isDisplay: false)],
      mathML: ["<math>X</math>"])

    #expect(result == """
      <p data-source-line="1">Let <span class="math inline">\
      <math>X</math></span> be.</p>
      """)
  }

  @Test("Display sentinel alone in a paragraph becomes a block, keeping attributes")
  func displayBlock() {
    let html = "<p data-source-line=\"3\">\(sentinel(0))</p>"
    let result = MathHTMLSubstitutor.substitute(
      in: html,
      spans: [MathSpan(tex: "a+b", isDisplay: true)],
      mathML: ["<math display=\"block\">AB</math>"])

    #expect(result == """
      <div class="math display" data-source-line="3">\
      <math display="block">AB</math></div>
      """)
  }

  @Test("Display sentinel inside running text stays inline-level")
  func displayInsideParagraph() {
    let html = "<p>so \(sentinel(0)) here</p>"
    let result = MathHTMLSubstitutor.substitute(
      in: html,
      spans: [MathSpan(tex: "E", isDisplay: true)],
      mathML: ["<math display=\"block\">E</math>"])

    #expect(result == """
      <p>so <span class="math display"><math display="block">E</math>\
      </span> here</p>
      """)
  }

  @Test("Every sentinel is replaced, in any order of appearance")
  func multiple() {
    let html = "<p>\(sentinel(1)) before \(sentinel(0))</p>"
    let result = MathHTMLSubstitutor.substitute(
      in: html,
      spans: [
        MathSpan(tex: "a", isDisplay: false),
        MathSpan(tex: "b", isDisplay: false)
      ],
      mathML: ["<math>A</math>", "<math>B</math>"])

    #expect(result == """
      <p><span class="math inline"><math>B</math></span> before \
      <span class="math inline"><math>A</math></span></p>
      """)
    #expect(!result.contains("\u{E000}"))
  }

  @Test("A sentinel inside a tag attribute becomes escaped TeX, not markup")
  func sentinelInsideAttribute() {
    let html = """
      <p><img src="a.png" alt="see \(sentinel(0))"> and \(sentinel(0)) \
      <a href="http://x/\(sentinel(1))">t</a></p>
      """
    let result = MathHTMLSubstitutor.substitute(
      in: html,
      spans: [
        MathSpan(tex: "a\"b", isDisplay: false),
        MathSpan(tex: "y", isDisplay: true)
      ],
      mathML: ["<math>AB</math>", "<math display=\"block\">Y</math>"])

    #expect(result == """
      <p><img src="a.png" alt="see $a&quot;b$"> and \
      <span class="math inline"><math>AB</math></span> \
      <a href="http://x/$$y$$">t</a></p>
      """)
  }

  @Test("HTML without sentinels passes through untouched")
  func passthrough() {
    let html = "<p>plain</p>"
    let result = MathHTMLSubstitutor.substitute(
      in: html, spans: [], mathML: [])

    #expect(result == html)
  }
}
