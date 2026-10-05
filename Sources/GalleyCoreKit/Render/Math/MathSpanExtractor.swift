//
//  MathSpanExtractor.swift
//  GalleyCoreKit
//
//  swift-markdown has no math syntax, and by the time its visitor runs a
//  formula like `$a_1 * b_2$` has already been split into emphasis
//  nodes. So math is lifted out *before* parsing: each `$…$` / `$$…$$`
//  span becomes an opaque sentinel built from private-use characters —
//  inert to Markdown and to HTML escaping — and `MathHTMLSubstitutor`
//  swaps the sentinels for MathML after rendering.
//
//  Delimiter rules follow pandoc's `tex_math_dollars`:
//  - `$$…$$` is display math and may span lines.
//  - `$…$` is inline math: the opening `$` must be followed and the
//    closing `$` preceded by a non-space character, the closing `$` may
//    not be followed by an ASCII digit, and the span may not cross a
//    blank line.
//  - `\$` is a literal dollar.
//  - Code spans and fenced code blocks (including fences inside
//    blockquotes) are left untouched.
//  - Blockquote `>` markers are stripped from the continuation lines of
//    a span that crosses lines, so `> $$ … > $$` yields clean TeX.
//
//  Not handled (left to the Markdown parser as ordinary text): dollars
//  inside indented code blocks, inside fences nested in list items, and
//  inside raw HTML blocks.
//

import Foundation

public enum MathSpanExtractor {
  static let sentinelOpen: Character = "\u{E000}"
  static let sentinelClose: Character = "\u{E001}"

  /// The placeholder written into the source for span number `index`.
  public static func sentinel(index: Int) -> String {
    "\(sentinelOpen)\(index)\(sentinelClose)"
  }

  public static func extract(from source: String) -> MathExtraction {
    // "\r\n" is a single `Character`, so a CRLF document would never
    // match the "\n" the scanner keys on. Normalize first — the line
    // count is unchanged and the Markdown parser does not care.
    let normalized = source.contains("\r\n")
      ? source.replacingOccurrences(of: "\r\n", with: "\n")
      : source
    var scanner = MathScanner(Array(normalized))
    scanner.run()
    return MathExtraction(source: scanner.output, spans: scanner.spans)
  }
}

// MARK: - Scanner

private struct MathScanner {
  private struct FenceRun {
    let marker: Character
    let length: Int
    /// Nothing but whitespace after the run — required of a closer.
    let isBare: Bool
    /// A backtick fence whose info string holds a backtick is no fence.
    let infoHasBacktick: Bool
  }

  private let chars: [Character]
  private var index = 0
  private var fence: (marker: Character, length: Int)?

  /// Positions before which an inline / display opener is known to
  /// have no closer. Once a scan from some opener fails, every later
  /// opener up to the point where that scan stopped (paragraph end or
  /// end of input) must fail too, so it is not re-scanned — without
  /// this, a long run of unmatched dollars is quadratic.
  private var inlineDeadEnd = 0
  private var displayDeadEnd = 0

  private(set) var output = ""
  private(set) var spans: [MathSpan] = []

  init(_ chars: [Character]) {
    self.chars = chars
    output.reserveCapacity(chars.count)
  }

  mutating func run() {
    while index < chars.count {
      scanLine()
    }
  }

  // MARK: Lines and fences

  /// Handles the line starting at `index`: fence bookkeeping first, then
  /// inline scanning. A multi-line span consumed by `step()` may leave
  /// `index` mid-way through a later line; the loop simply carries on
  /// scanning the remainder of that line.
  private mutating func scanLine() {
    let lineEnd = endOfLine(from: index)
    if let run = fenceRun(in: index..<lineEnd) {
      updateFence(with: run)
      emit(through: min(lineEnd + 1, chars.count))
      return
    }
    if fence != nil {
      emit(through: min(lineEnd + 1, chars.count))
      return
    }
    while index < chars.count, chars[index] != "\n" {
      step()
    }
    if index < chars.count {
      emit(count: 1)
    }
  }

  private func endOfLine(from start: Int) -> Int {
    var cursor = start
    while cursor < chars.count, chars[cursor] != "\n" {
      cursor += 1
    }
    return cursor
  }

  private func fenceRun(in range: Range<Int>) -> FenceRun? {
    var cursor = skipQuoteMarkers(from: range.lowerBound, to: range.upperBound)
    var indent = 0
    while cursor < range.upperBound, chars[cursor] == " ", indent < 3 {
      cursor += 1
      indent += 1
    }
    guard cursor < range.upperBound,
          chars[cursor] == "`" || chars[cursor] == "~"
    else { return nil }
    let marker = chars[cursor]
    var length = 0
    while cursor < range.upperBound, chars[cursor] == marker {
      cursor += 1
      length += 1
    }
    guard length >= 3 else { return nil }
    let info = chars[cursor..<range.upperBound]
    return FenceRun(
      marker: marker,
      length: length,
      isBare: info.allSatisfy(\.isWhitespace),
      infoHasBacktick: info.contains("`"))
  }

  /// Skips blockquote markers — each `>` may have up to three spaces
  /// before it and one after — so a fence inside a quote is still seen.
  private func skipQuoteMarkers(from start: Int, to end: Int) -> Int {
    var cursor = start
    while true {
      var probe = cursor
      var spaces = 0
      while probe < end, chars[probe] == " ", spaces < 3 {
        probe += 1
        spaces += 1
      }
      guard probe < end, chars[probe] == ">" else { return cursor }
      probe += 1
      if probe < end, chars[probe] == " " {
        probe += 1
      }
      cursor = probe
    }
  }

  private mutating func updateFence(with run: FenceRun) {
    if let open = fence {
      if run.marker == open.marker, run.length >= open.length, run.isBare {
        fence = nil
      }
    } else if !(run.marker == "`" && run.infoHasBacktick) {
      fence = (run.marker, run.length)
    }
  }

  // MARK: Inline scanning

  private mutating func step() {
    switch chars[index] {
    case "\\":
      emit(count: min(escapeLength(at: index), chars.count - index))
    case "`":
      scanCodeSpan()
    case "$":
      if character(at: index + 1) == "$" {
        scanDisplayMath()
      } else {
        scanInlineMath()
      }
    default:
      emit(count: 1)
    }
  }

  /// CommonMark code span: a backtick run opens a span only if a run of
  /// exactly the same length follows in the same paragraph.
  private mutating func scanCodeSpan() {
    let length = runLength(of: "`", at: index)
    var cursor = index + length
    while cursor < chars.count {
      if chars[cursor] == "\n", isBlankLine(startingAt: cursor + 1) {
        break
      }
      if chars[cursor] == "`" {
        let closing = runLength(of: "`", at: cursor)
        if closing == length {
          emit(through: cursor + closing)
          return
        }
        cursor += closing
        continue
      }
      cursor += 1
    }
    emit(count: length)
  }

  private mutating func scanDisplayMath() {
    guard index >= displayDeadEnd else {
      emit(count: 2)
      return
    }
    let start = index + 2
    var cursor = start
    while cursor + 1 < chars.count {
      if chars[cursor] == "\\" {
        cursor += escapeLength(at: cursor)
        continue
      }
      if chars[cursor] == "$", chars[cursor + 1] == "$" {
        let tex = texText(from: start, to: cursor)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if tex.isEmpty { break }
        append(MathSpan(tex: tex, isDisplay: true), consuming: cursor + 2)
        return
      }
      cursor += 1
    }
    if cursor + 1 >= chars.count {
      // No `$$` anywhere after this opener; later openers can't find
      // one either.
      displayDeadEnd = chars.count
    }
    emit(count: 2)
  }

  private mutating func scanInlineMath() {
    guard index >= inlineDeadEnd else {
      emit(count: 1)
      return
    }
    let start = index + 1
    guard let first = character(at: start), !first.isWhitespace else {
      emit(count: 1)
      return
    }
    var cursor = start
    while cursor < chars.count {
      let current = chars[cursor]
      if current == "\\" {
        cursor += escapeLength(at: cursor)
        continue
      }
      if current == "\n", isBlankLine(startingAt: cursor + 1) {
        break
      }
      if current == "$", closesInlineMath(at: cursor) {
        let tex = texText(from: start, to: cursor)
        append(MathSpan(tex: tex, isDisplay: false), consuming: cursor + 1)
        return
      }
      cursor += 1
    }
    inlineDeadEnd = cursor
    emit(count: 1)
  }

  /// A closing `$` needs a non-space before it and no ASCII digit after
  /// it (`$5 and $6` is prose, not math).
  private func closesInlineMath(at cursor: Int) -> Bool {
    guard !chars[cursor - 1].isWhitespace else { return false }
    guard let next = character(at: cursor + 1) else { return true }
    return !("0"..."9").contains(next)
  }

  // MARK: Helpers

  private func character(at position: Int) -> Character? {
    position < chars.count ? chars[position] : nil
  }

  /// A backslash escapes the character after it — except a newline,
  /// which must stay visible to the line and blank-line logic.
  private func escapeLength(at position: Int) -> Int {
    character(at: position + 1) == "\n" ? 1 : 2
  }

  private func runLength(of marker: Character, at start: Int) -> Int {
    var cursor = start
    while cursor < chars.count, chars[cursor] == marker {
      cursor += 1
    }
    return cursor - start
  }

  /// `true` when the line beginning at `start` is empty or whitespace
  /// only (or `start` is past the end of input).
  private func isBlankLine(startingAt start: Int) -> Bool {
    var cursor = start
    while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
      cursor += 1
    }
    return cursor >= chars.count || chars[cursor] == "\n"
  }

  /// The TeX between `start` and `end`, with blockquote markers removed
  /// from the start of every continuation line.
  private func texText(from start: Int, to end: Int) -> String {
    let raw = String(chars[start..<end])
    guard raw.contains("\n") else { return raw }
    return raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .map { offset, line -> String in
        if offset == 0 { return String(line) }
        return String(line.replacing(#/^[ \t]*(?:>[ ]?)+/#, with: ""))
      }
      .joined(separator: "\n")
  }

  /// Writes the sentinel for `span` in place of `chars[index..<end]`.
  ///
  /// A span that crossed lines would otherwise shorten the document and
  /// shift every later `data-source-line`, breaking cmd-click → editor.
  /// When the span ends its line (the usual `$$ … $$` block shape), the
  /// swallowed newlines are re-emitted after the sentinel; they only
  /// add blank lines where the paragraph ends anyway. A multi-line span
  /// followed by more text on its closing line is left unpadded, since
  /// a newline there would split the paragraph.
  private mutating func append(_ span: MathSpan, consuming end: Int) {
    output += MathSpanExtractor.sentinel(index: spans.count)
    let newlines = chars[index..<end].count { $0 == "\n" }
    if newlines > 0, isBlankLine(startingAt: end) {
      output += String(repeating: "\n", count: newlines)
    }
    spans.append(span)
    index = end
  }

  private mutating func emit(count: Int) {
    emit(through: index + count)
  }

  private mutating func emit(through end: Int) {
    output.append(contentsOf: chars[index..<end])
    index = end
  }
}
