//
//  MathHTMLSubstitutor.swift
//  GalleyCoreKit
//
//  Post-pass of the TeX-math pipeline: replaces the sentinels that
//  `MathSpanExtractor` wrote into the Markdown source with rendered
//  MathML, after swift-markdown has produced the HTML.
//
//  Output shape mirrors pandoc's, so template CSS can target both
//  processors the same way:
//    inline  → <span class="math inline"><math>…</math></span>
//    display → <div class="math display"><math display="block">…</math></div>
//  A display span that was the sole content of a paragraph becomes the
//  `<div>` (a `<div>` inside `<p>` is invalid HTML), keeping the
//  paragraph's attributes such as `data-source-line`. Display math that
//  sits inside running text stays a `<span class="math display">`.
//

import Foundation

public enum MathHTMLSubstitutor {
  /// `mathML[i]` is the `<math>` element for `spans[i]`.
  public static func substitute(
    in html: String, spans: [MathSpan], mathML: [String]
  ) -> String {
    precondition(spans.count == mathML.count, "one MathML string per span")
    var result = neutralizeSentinelsInsideTags(in: html, spans: spans)
    for (index, span) in spans.enumerated() {
      let sentinel = MathSpanExtractor.sentinel(index: index)
      let markup = mathML[index]
      if span.isDisplay {
        result = replaceParagraph(
          holding: sentinel, in: result, with: markup)
      }
      let cssClass = span.isDisplay ? "math display" : "math inline"
      result = result.replacingOccurrences(
        of: sentinel,
        with: "<span class=\"\(cssClass)\">\(markup)</span>")
    }
    return result
  }

  /// Stand-in for a span the math engine could not render: the escaped
  /// TeX source with its delimiters, marked up so a template can style
  /// it, with the failure reason in the tooltip. Goes where the
  /// `<math>` element would have gone, so it still gets the inline /
  /// display wrapper from `substitute`.
  public static func errorMarkup(for span: MathSpan, reason: String) -> String {
    let title = reason.htmlAttributeEscaped
    let body = delimited(span).htmlEscaped
    return "<span class=\"math error\" title=\"\(title)\">\(body)</span>"
  }

  /// A sentinel that landed inside a tag — image alt text, a link title
  /// or destination (`![$x$](a.png)`) — cannot hold markup: the
  /// MathML's quotes would end the attribute early. Put the TeX back
  /// there as attribute-escaped text with its delimiters.
  private static func neutralizeSentinelsInsideTags(
    in html: String, spans: [MathSpan]
  ) -> String {
    guard !spans.isEmpty else { return html }
    return html.replacing(#/<[A-Za-z][^>]*>/#) { match in
      var tag = String(match.output)
      guard tag.contains(MathSpanExtractor.sentinelOpen) else { return tag }
      for (index, span) in spans.enumerated() {
        tag = tag.replacingOccurrences(
          of: MathSpanExtractor.sentinel(index: index),
          with: delimited(span).htmlAttributeEscaped)
      }
      return tag
    }
  }

  private static func delimited(_ span: MathSpan) -> String {
    let delimiter = span.isDisplay ? "$$" : "$"
    return delimiter + span.tex + delimiter
  }

  /// `<p attrs>SENTINEL</p>` → `<div class="math display" attrs>…</div>`.
  private static func replaceParagraph(
    holding sentinel: String, in html: String, with markup: String
  ) -> String {
    let pattern = "<p((?:\\s[^>]*)?)>\\s*"
      + NSRegularExpression.escapedPattern(for: sentinel)
      + "\\s*</p>"
    guard let regex = try? Regex(pattern) else { return html }
    return html.replacing(regex) { match in
      let attributes = match.output[1].substring.map(String.init) ?? ""
      return "<div class=\"math display\"\(attributes)>\(markup)</div>"
    }
  }
}
