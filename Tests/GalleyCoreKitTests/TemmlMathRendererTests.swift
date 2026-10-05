//
//  TemmlMathRendererTests.swift
//  Galley
//
//  Exercises the vendored Temml build running inside JavaScriptCore:
//  TeX in, a `<math>` element out, with the source TeX preserved in an
//  `<annotation>` and parse errors surfaced in the markup rather than
//  thrown (so one bad formula can't take down a whole document).
//

import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("TemmlMathRenderer")
struct TemmlMathRendererTests {
  @Test("Inline TeX renders to a bare MathML element")
  func inline() async throws {
    let renderer = TemmlMathRenderer()

    let mathML = try await renderer.render(
      MathSpan(tex: "x_i^2", isDisplay: false))

    #expect(mathML.hasPrefix("<math"))
    #expect(mathML.hasSuffix("</math>"))
    #expect(mathML.contains("<msubsup>") || mathML.contains("<msup>"))
    // No <semantics>/<annotation> wrapper — see TemmlMathRenderer:
    // WebKit renders a tagged equation inside <semantics> as a blank.
    #expect(!mathML.contains("<semantics>"))
    #expect(!mathML.contains("<annotation"))
    #expect(!mathML.contains("display=\"block\""))
  }

  @Test("A tagged equation is an unwrapped table with the tag cell")
  func taggedEquation() async throws {
    let renderer = TemmlMathRenderer()

    let mathML = try await renderer.render(
      MathSpan(tex: #"E = mc^2 \tag{1}"#, isDisplay: true))

    #expect(mathML.hasPrefix("<math display=\"block\""))
    #expect(mathML.contains("<mtable"))
    #expect(mathML.contains("<mtext class=\"tml-tag\">(1)</mtext>"))
    #expect(!mathML.contains("<semantics>"))
  }

  @Test("Display TeX renders in block mode")
  func display() async throws {
    let renderer = TemmlMathRenderer()

    let mathML = try await renderer.render(
      MathSpan(tex: #"\int_0^1 f(x)\,dx"#, isDisplay: true))

    #expect(mathML.hasPrefix("<math"))
    #expect(mathML.contains("display=\"block\""))
    #expect(mathML.contains("∫"))
  }

  @Test("A parse error is reported in the markup, not thrown")
  func parseError() async throws {
    let renderer = TemmlMathRenderer()

    // With `throwOnError: false` Temml returns a styled error span
    // holding the source and the message instead of a `<math>`.
    let markup = try await renderer.render(
      MathSpan(tex: #"\frac{"#, isDisplay: false))

    #expect(markup.hasPrefix("<span class=\"temml-error\""))
    #expect(markup.contains("ParseError"))
    #expect(markup.contains(#"\frac{"#))
  }

  @Test("An unknown command is flagged inside otherwise valid MathML")
  func unknownCommand() async throws {
    let renderer = TemmlMathRenderer()

    let mathML = try await renderer.render(
      MathSpan(tex: #"\unknowncmd x"#, isDisplay: false))

    #expect(mathML.hasPrefix("<math"))
    #expect(mathML.contains("<mtext style=\"color:#b22222;\">\\unknowncmd</mtext>"))
  }

  @Test("Repeated renders on one engine stay independent")
  func repeated() async throws {
    let renderer = TemmlMathRenderer()

    let first = try await renderer.render(
      MathSpan(tex: "a", isDisplay: false))
    let second = try await renderer.render(
      MathSpan(tex: "b", isDisplay: false))

    #expect(first.contains("<mi>a</mi>"))
    #expect(second.contains("<mi>b</mi>"))
    #expect(!second.contains("<mi>a</mi>"))
  }
}
