import Foundation
import MarkdownHTMLKit

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
public struct SwiftMarkdownRenderer: MarkdownRenderer {
  public init() {
  }

  public func render(_ source: String, baseURL: URL) async throws -> String {
    MarkdownHTML.render(source, annotatesSourceLines: true)
  }
}
