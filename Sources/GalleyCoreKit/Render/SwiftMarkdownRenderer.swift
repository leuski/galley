import Foundation
import MarkdownHTMLKit
import os

/// Built-in renderer backed by `swiftlang/swift-markdown`. Always available
/// and used as the default fallback when no external processor is selected.
///
/// The actual markdown → HTML rendering lives in the shared
/// `MarkdownHTMLKit` package (used by both Galley and Dot). This type is
/// the thin Galley-side adapter conforming to `MarkdownRenderer`.
///
/// `annotatesSourceLines` is left on: every block element receives a
/// `data-source-line="N"` attribute pointing back at the originating line
/// in the markdown source — invisible to readers, but lets Galley's
/// editor-coupling code map clicks in the preview back to the source.
///
/// TeX math (`$…$` / `$$…$$`) is not Markdown syntax, so it is handled
/// around the parser: `MathSpanExtractor` lifts each span out of the
/// source before parsing, `mathRenderer` turns it into MathML, and
/// `MathHTMLSubstitutor` puts the MathML back into the rendered HTML.
/// Pass `mathRenderer: nil` to leave dollars as ordinary text.
public struct SwiftMarkdownRenderer: MarkdownRenderer {
  private let mathRenderer: (any TeXMathRenderer)?

  public init(
    mathRenderer: (any TeXMathRenderer)? = TemmlMathRenderer.shared
  ) {
    self.mathRenderer = mathRenderer
  }

  public func render(_ source: String, baseURL: URL) async throws -> String {
    guard let mathRenderer else {
      return MarkdownHTML.render(source, annotatesSourceLines: true)
    }
    let extraction = MathSpanExtractor.extract(from: source)
    guard !extraction.spans.isEmpty else {
      return MarkdownHTML.render(source, annotatesSourceLines: true)
    }
    let html = MarkdownHTML.render(
      extraction.source, annotatesSourceLines: true)
    var mathML: [String] = []
    mathML.reserveCapacity(extraction.spans.count)
    for span in extraction.spans {
      mathML.append(await Self.mathML(for: span, using: mathRenderer))
    }
    return MathHTMLSubstitutor.substitute(
      in: html, spans: extraction.spans, mathML: mathML)
  }

  /// One failed formula must not take the whole document down: on an
  /// engine error the span degrades to its escaped TeX source, marked
  /// up so a template can style it, with the reason in the tooltip.
  private static func mathML(
    for span: MathSpan, using renderer: any TeXMathRenderer
  ) async -> String {
    do {
      return try await renderer.render(span)
    } catch {
      let reason = String(describing: error)
      logger.error("math render failed: \(reason, privacy: .public)")
      logger.debug("failed TeX: \(span.tex, privacy: .private)")
      return MathHTMLSubstitutor.errorMarkup(for: span, reason: reason)
    }
  }
}

private let logger = Logger(category: "SwiftMarkdownRenderer")
