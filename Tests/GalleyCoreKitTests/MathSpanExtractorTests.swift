//
//  MathSpanExtractorTests.swift
//  Galley
//
//  The extractor lifts `$…$` / `$$…$$` TeX spans out of Markdown source
//  *before* swift-markdown sees it, replacing each with an opaque
//  sentinel. These tests pin the delimiter rules (pandoc's
//  `tex_math_dollars`) and the regions that must be left alone (code
//  spans, fenced code, escaped dollars).
//

import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("MathSpanExtractor")
struct MathSpanExtractorTests {
  private func sentinel(_ index: Int) -> String {
    MathSpanExtractor.sentinel(index: index)
  }

  @Test("Inline span is replaced by a sentinel and captured")
  func inlineSpan() {
    let result = MathSpanExtractor.extract(from: "Let $x^2$ be.")

    #expect(result.source == "Let \(sentinel(0)) be.")
    #expect(result.spans == [MathSpan(tex: "x^2", isDisplay: false)])
  }

  @Test("Display block spanning lines is captured trimmed")
  func displayBlock() {
    let source = """
      Before

      $$
      a + b
      $$

      After
      """
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans == [MathSpan(tex: "a + b", isDisplay: true)])
    // The two newlines swallowed by the block are re-emitted after the
    // sentinel so later lines keep their numbers (`data-source-line`).
    #expect(result.source == "Before\n\n\(sentinel(0))\n\n\n\nAfter")
    #expect(lineCount(result.source) == lineCount(source))
  }

  @Test("Multi-line span followed by text on its closing line is not padded")
  func multiLineSpanMidLine() {
    let result = MathSpanExtractor.extract(from: "$a\nb$ tail")

    #expect(result.spans == [MathSpan(tex: "a\nb", isDisplay: false)])
    #expect(result.source == "\(sentinel(0)) tail")
  }

  private func lineCount(_ text: String) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: false).count
  }

  @Test("Double-dollar on one line is display math")
  func displayInline() {
    let result = MathSpanExtractor.extract(from: "so $$E=mc^2$$ here")

    #expect(result.spans == [MathSpan(tex: "E=mc^2", isDisplay: true)])
    #expect(result.source == "so \(sentinel(0)) here")
  }

  @Test("Spans are numbered in document order")
  func ordering() {
    let result = MathSpanExtractor.extract(from: "$a$ then $b$ then $$c$$")

    #expect(result.spans.map(\.tex) == ["a", "b", "c"])
    #expect(result.source
            == "\(sentinel(0)) then \(sentinel(1)) then \(sentinel(2))")
  }

  @Test("Escaped dollar is not a delimiter")
  func escapedDollar() {
    let source = #"It costs \$5 and \$6."#
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans.isEmpty)
    #expect(result.source == source)
  }

  @Test("Closing dollar followed by a digit does not close")
  func digitAfterClose() {
    let source = "Costs $5 and $6 total."
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans.isEmpty)
    #expect(result.source == source)
  }

  @Test("Whitespace directly inside the delimiters disqualifies the span")
  func whitespaceInsideDelimiters() {
    for source in ["a $ b$ c", "a $b $ c", "a $ b $ c"] {
      let result = MathSpanExtractor.extract(from: source)
      #expect(result.spans.isEmpty, "\(source)")
      #expect(result.source == source)
    }
  }

  @Test("Unclosed dollar is left alone")
  func unclosed() {
    let source = "a $b c"
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans.isEmpty)
    #expect(result.source == source)
  }

  @Test("Inline span may not cross a blank line")
  func noBlankLineInsideInline() {
    let source = "$a\n\nb$"
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans.isEmpty)
    #expect(result.source == source)
  }

  @Test("Dollars inside a code span are untouched")
  func codeSpan() {
    let source = "Use `$x$` literally, but $y$ is math."
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans == [MathSpan(tex: "y", isDisplay: false)])
    #expect(result.source == "Use `$x$` literally, but \(sentinel(0)) is math.")
  }

  @Test("Double-backtick code span containing a single backtick is skipped")
  func doubleBacktickCodeSpan() {
    let source = "`` $a` `` and $b$"
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans == [MathSpan(tex: "b", isDisplay: false)])
    #expect(result.source == "`` $a` `` and \(sentinel(0))")
  }

  @Test("Dollars inside a fenced code block are untouched")
  func fencedBlock() {
    let source = """
      ```sh
      echo $HOME and $PATH
      ```

      Then $z$.
      """
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans == [MathSpan(tex: "z", isDisplay: false)])
    #expect(result.source == """
      ```sh
      echo $HOME and $PATH
      ```

      Then \(sentinel(0)).
      """)
  }

  @Test("Tilde fence with a longer closing fence is honored")
  func tildeFence() {
    let source = """
      ~~~
      $a$
      ~~~~

      $b$
      """
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans == [MathSpan(tex: "b", isDisplay: false)])
  }

  @Test("Markdown emphasis characters inside math are protected")
  func emphasisInsideMath() {
    let result = MathSpanExtractor.extract(from: "$a_1 * b_2$ and *em*")

    #expect(result.spans == [MathSpan(tex: "a_1 * b_2", isDisplay: false)])
    #expect(result.source == "\(sentinel(0)) and *em*")
  }

  @Test("Empty input yields empty output")
  func empty() {
    let result = MathSpanExtractor.extract(from: "")

    #expect(result.spans.isEmpty)
    #expect(result.source == "")
  }

  // MARK: Review follow-ups

  @Test("CRLF line endings: blank lines, fences, and padding still work")
  func crlf() {
    let paragraphs = "Cost $5 each\r\n\r\nand 5$ more"
    #expect(MathSpanExtractor.extract(from: paragraphs).spans.isEmpty)

    let fenced = "```\r\n$a$\r\n```\r\n$b$"
    #expect(MathSpanExtractor.extract(from: fenced).spans
            == [MathSpan(tex: "b", isDisplay: false)])

    let block = "$$\r\nx\r\n$$\r\n\r\nafter"
    let result = MathSpanExtractor.extract(from: block)
    #expect(result.spans == [MathSpan(tex: "x", isDisplay: true)])
    #expect(result.source == "\(sentinel(0))\n\n\n\nafter")
  }

  @Test("A fence inside a blockquote is recognized")
  func blockquoteFence() {
    let source = "> ```\n> $a$\n> ```\n\n$b$"
    let result = MathSpanExtractor.extract(from: source)

    #expect(result.spans == [MathSpan(tex: "b", isDisplay: false)])
  }

  @Test("Blockquote markers are stripped from continuation lines of a span")
  func blockquoteContinuation() {
    let display = MathSpanExtractor.extract(from: "> $$\n> x = 1\n> $$")
    #expect(display.spans == [MathSpan(tex: "x = 1", isDisplay: true)])

    let inline = MathSpanExtractor.extract(from: "> a $x +\n> y$ b")
    #expect(inline.spans == [MathSpan(tex: "x +\ny", isDisplay: false)])
  }

  @Test("A backslash before a newline does not swallow the newline")
  func backslashBeforeNewline() {
    let fenced = "line\\\n```\n$a$ and $b$\n\nmore $c$\n```"
    #expect(MathSpanExtractor.extract(from: fenced).spans.isEmpty)

    let paragraphs = "a $x\\\n\ny$ b"
    #expect(MathSpanExtractor.extract(from: paragraphs).spans.isEmpty)
  }

  @Test("Only an ASCII digit blocks a closing dollar")
  func asciiDigitRule() {
    let result = MathSpanExtractor.extract(from: "$x$½ and $y$٣")

    #expect(result.spans.map(\.tex) == ["x", "y"])
  }

  @Test("Many unmatched dollars scan in linear time")
  func unmatchedDollarsAreCheap() {
    // Every `$` here is an opener with no valid closer (each candidate
    // closer is preceded by a space), across two paragraphs.
    let source = String(repeating: "$a ", count: 20_000)
      + "\n\n" + String(repeating: "$5 ", count: 20_000)
    let clock = ContinuousClock()

    let elapsed = clock.measure {
      let result = MathSpanExtractor.extract(from: source)
      #expect(result.spans.isEmpty)
      #expect(result.source == source)
    }

    #expect(elapsed < .seconds(2))
  }
}
