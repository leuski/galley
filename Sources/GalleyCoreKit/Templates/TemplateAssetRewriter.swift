import Foundation
import KosmosAppKit

/// Rewrites asset references inside a template's HTML so they resolve
/// through the kit's well-known routes (`/template/<id>/<file>` and
/// `/preview/<absolute-path>`) regardless of whether the previewing
/// surface is the HTTP server, the Viewer's `x-galley://` scheme
/// handler, or the offscreen print/export WebView.
///
/// Two separate passes:
/// - tag-attribute URLs (`<link href>`, `<script src>`, `<img src>`,
///   `<source src>`, `<track src>`, `<video src>`, `<audio src>`,
///   `<iframe src>`, `<object data>`, `<embed src>`).
/// - `url(...)` references inside `<style>` blocks.
///
/// The rewriter is shared by every template (bundled and user-defined)
/// because all of them produce HTML that goes through the same render
/// pipeline and must reference assets via the same routes.
struct TemplateAssetRewriter {
  let templatePrefix: String
  let absolutePrefix: String

  init(id: String, origin: URL) {
    self.templatePrefix = origin.galleyTemplate(id: id)
      .absoluteString.appendingSlash
    self.absolutePrefix = origin.galleyPreview
      .absoluteString
  }

  func rewriteAssets(in html: String) -> String {
    rewriteCSSURLs(html: rewriteAttributeURLs(html: html))
  }

  // MARK: - Asset URL rewriting

  // Tags that load resources (not navigation links).
  nonisolated(unsafe) private static let templateAssetRegex = #/
  (?i)
  (<\s*(?:link|script|img|source|track|video|audio|iframe|object|embed)
  \b[^>]*?\b(?:src|href|data)\s*=\s*")
  ([^"]*)
  ("[^>]*>)
  /#

  // url(...) inside <style> blocks. Matches url("…"), url('…'), url(…).
  nonisolated(unsafe) private static let cssUrlRegex =
  #/(?i)url\(\s*(['"]?)([^'")]+)\1\s*\)/#

  private func rewriteAttributeURLs(html: String) -> String {
    html.replacing(Self.templateAssetRegex) { match in
      let (_, openTag, value, closeTag) = match.output
      let original = String(value)
      let replaced = rewriteAssetURL(original)
      return "\(openTag)\(replaced)\(closeTag)"
    }
  }

  private func rewriteCSSURLs(html: String) -> String {
    html.replacing(Self.cssUrlRegex) { match in
      let whole = match.output.0
      let value = match.output.2
      let original = String(value)
      let replaced = rewriteAssetURL(original)
      let prefix = whole[whole.startIndex..<value.startIndex]
      let suffix = whole[value.endIndex..<whole.endIndex]
      return "\(prefix)\(replaced)\(suffix)"
    }
  }

  private func rewriteAssetURL(_ value: String) -> String {
    guard !value.isEmpty else { return value }

    // Skip BBEdit-style placeholders (e.g. #DOCUMENT_CONTENT#, #BASE#).
    if value.hasPrefix("#"), value.hasSuffix("#"), value.count >= 2 {
      return value
    }
    // Skip in-page anchors.
    if value.hasPrefix("#") { return value }
    // Skip protocol-relative URLs.
    if value.hasPrefix("//") { return value }
    // Skip absolute URLs with a scheme.
    if let url = URL(string: value),
       let scheme = url.scheme, !scheme.isEmpty
    {
      return value
    }

    if value.hasPrefix("/") {
      // BBEdit convention: literal absolute filesystem paths. Route through
      // /preview.
      return absolutePrefix + value.percentEncodedForPath
    }

    // Template-relative path. Encode the value to handle spaces, etc.
    return templatePrefix + value.percentEncodedForPath
  }
}
