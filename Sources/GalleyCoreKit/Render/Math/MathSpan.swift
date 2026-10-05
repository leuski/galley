//
//  MathSpan.swift
//  GalleyCoreKit
//
//  Value types shared by the TeX-math pipeline that wraps the built-in
//  Markdown processor: `MathSpanExtractor` (source → sentinels + spans),
//  a `TeXMathRenderer` (span → MathML), and `MathHTMLSubstitutor`
//  (sentinels in rendered HTML → MathML).
//

import Foundation

/// One TeX formula lifted out of a Markdown source.
public struct MathSpan: Equatable, Sendable {
  /// The TeX between the delimiters, with surrounding whitespace trimmed.
  public let tex: String
  /// `true` for `$$…$$` (block / display mode), `false` for `$…$`.
  public let isDisplay: Bool

  public init(tex: String, isDisplay: Bool) {
    self.tex = tex
    self.isDisplay = isDisplay
  }
}

/// Markdown source with every math span replaced by a sentinel, plus the
/// spans in sentinel order (`spans[i]` corresponds to
/// `MathSpanExtractor.sentinel(index: i)`).
public struct MathExtraction: Sendable {
  public let source: String
  public let spans: [MathSpan]
}

/// Turns one TeX span into a `<math>…</math>` element. Implementations
/// must be safe to call from any task; `TemmlMathRenderer` is the
/// shipping one.
public protocol TeXMathRenderer: Sendable {
  func render(_ span: MathSpan) async throws -> String
}
