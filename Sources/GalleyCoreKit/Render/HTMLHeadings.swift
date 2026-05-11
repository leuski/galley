import Foundation

/// Lightweight HTML scanner for the rendered document's first level-1
/// heading. Used by `Template.composeHTML` to give the `#TITLE#`
/// placeholder a semantic value — the author-intended document title
/// — rather than just the filename.
///
/// Reads the *rendered body* (the output of whichever Markdown
/// processor ran) so the title reflects whatever syntax produced the
/// `<h1>` — MMD `Title:` metadata that materializes as a heading,
/// Pandoc title blocks, plain `# Heading`, raw HTML, etc. All
/// processors emit `<h1>` regardless of source syntax, so one scanner
/// covers them all.
///
/// Not a full HTML parser. Heading content is constrained: no nested
/// headings, no `<script>`/`<style>`, only inline formatting elements
/// (`<em>`, `<code>`, `<a>`, …). Stripping `<…>` and decoding the five
/// common entities is sufficient.
public enum HTMLHeadings {
  /// Plain-text content of the first `<h1>` in `body`, with inline
  /// tags stripped, common HTML entities decoded, whitespace
  /// collapsed, and trimmed. Returns `nil` when there is no `<h1>`
  /// or the heading is empty.
  public static func firstH1Text(in body: String) -> String? {
    // Match `<h1>` or `<h1 attr=...>`, but not `<h10>` (no such tag,
    // but the boundary guards future-proof us).
    guard let openRange = body.range(
      of: #"<h1(?:\s[^>]*)?>"#,
      options: .regularExpression)
    else { return nil }
    let bodyAfterOpen = body[openRange.upperBound...]
    guard let closeRange = bodyAfterOpen.range(
      of: "</h1>",
      options: .caseInsensitive)
    else { return nil }
    let inner = String(bodyAfterOpen[..<closeRange.lowerBound])
    let stripped = inner.replacingOccurrences(
      of: #"<[^>]+>"#,
      with: "",
      options: .regularExpression)
    let decoded = decodeCommonHTMLEntities(in: stripped)
    let collapsed = decoded.replacingOccurrences(
      of: #"\s+"#,
      with: " ",
      options: .regularExpression)
    let trimmed = collapsed.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Decodes the five entities Markdown renderers actually emit in
  /// heading text (and numeric escapes that show up for non-ASCII
  /// quote marks, em-dashes, etc.). Skips the rest of the HTML
  /// entity catalog — a full decoder would pull in either
  /// `NSAttributedString` HTML parsing or a dictionary of named
  /// entities, and the long tail doesn't appear in real heading
  /// text.
  private static func decodeCommonHTMLEntities(in source: String) -> String {
    var result = source.replacingOccurrences(of: "&lt;", with: "<")
    result = result.replacingOccurrences(of: "&gt;", with: ">")
    result = result.replacingOccurrences(of: "&quot;", with: "\"")
    result = result.replacingOccurrences(of: "&#39;", with: "'")
    result = result.replacingOccurrences(of: "&apos;", with: "'")
    result = decodeNumericEntities(in: result)
    // Ampersand last so we don't double-decode entities whose
    // expansion contained `&`.
    result = result.replacingOccurrences(of: "&amp;", with: "&")
    return result
  }

  private static func decodeNumericEntities(in source: String) -> String {
    let pattern = #"&#(x[0-9a-fA-F]+|[0-9]+);"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return source
    }
    let nsSource = source as NSString
    let matches = regex.matches(
      in: source,
      range: NSRange(location: 0, length: nsSource.length))
    var result = source
    // Replace from the tail so earlier ranges stay valid.
    for match in matches.reversed() {
      let digits = nsSource.substring(with: match.range(at: 1))
      let scalar: Unicode.Scalar?
      if digits.first == "x" || digits.first == "X" {
        let hex = digits.dropFirst()
        scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init)
      } else {
        scalar = UInt32(digits).flatMap(Unicode.Scalar.init)
      }
      guard let scalar else { continue }
      let replacement = String(Character(scalar))
      let range = Range(match.range, in: result)
      if let range { result.replaceSubrange(range, with: replacement) }
    }
    return result
  }
}
