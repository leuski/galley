import Foundation
import AppKit
import Testing
@testable import GalleyCoreKit

/// Regression coverage for the rich-text clipboard path documented in
/// `docs/future-development.md` §2.2. Edit → Copy on a `WKWebView` puts
/// `public.html` and `public.rtf` on the pasteboard; native paste
/// targets (Mail, Notes, Pages, TextEdit) ultimately route through
/// `NSAttributedString(html:options:)`. This suite drives that exact
/// pipeline against every bundled template so a template/CSS tweak
/// that silently collapses the formatted-paste output trips the test.
@Suite("Clipboard round trip")
@MainActor
struct ClipboardRoundTripTests {

  private static let fixtureMarkdown: String = """
    # Heading One

    ## Heading Two

    ### Heading Three

    #### Heading Four

    ##### Heading Five

    ###### Heading Six

    A paragraph with **bold marker text**, *italic marker text*, and \
    `inline code marker` inside it.

    ```
    fenced code marker line one
    fenced code marker line two
    ```

    - unordered alpha
    - unordered beta
    - unordered gamma

    1. ordered uno
    2. ordered dos
    3. ordered tres

    > A blockquote marker.

    [Galley link marker](https://galley.example/path)

    ![alt marker](https://example.com/image.png)

    | Header A | Header B |
    | --- | --- |
    | cell one a | cell one b |
    | cell two a | cell two b |
    """

  nonisolated private static func bundledTemplates() -> [Template] {
    let manager = FileManager.default
    let dir = URL.bundleTemplatesDirectoryURL
    let contents = (try? manager.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])) ?? []
    let templates = contents
      .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
      .compactMap { Template(entryURL: $0, sourceIndex: 0) }
    return templates.sorted { $0.id < $1.id }
  }

  private static func composedHTML(
    template: Template
  ) async throws -> String {
    let renderer = SwiftMarkdownRenderer()
    let documentURL = URL(fileURLWithPath: "/tmp/clipboard-fixture.md")
    let origin = URL(string: "x-galley://local")!
    let body = try await renderer.render(
      fixtureMarkdown, baseURL: documentURL)
    let composed = try template.composeHTML(
      documentContent: body,
      documentURL: documentURL,
      origin: origin)
    return composed.html
  }

  private static func attributedString(
    fromHTML html: String
  ) throws -> NSAttributedString {
    let data = Data(html.utf8)
    return try NSAttributedString(
      data: data,
      options: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue
      ],
      documentAttributes: nil)
  }

  /// Collects every distinct point size that appears in the run table.
  /// Used as a coarse signal that headings outsize body copy.
  private static func pointSizes(
    in attributed: NSAttributedString
  ) -> Set<CGFloat> {
    var sizes: Set<CGFloat> = []
    let range = NSRange(location: 0, length: attributed.length)
    attributed.enumerateAttribute(.font, in: range) { value, _, _ in
      if let font = value as? NSFont {
        sizes.insert(font.pointSize.rounded())
      }
    }
    return sizes
  }

  private static func hasRun(
    in attributed: NSAttributedString,
    where predicate: (NSAttributedString) -> Bool
  ) -> Bool {
    let range = NSRange(location: 0, length: attributed.length)
    var found = false
    attributed.enumerateAttributes(in: range) { _, runRange, stop in
      let substring = attributed.attributedSubstring(from: runRange)
      if predicate(substring) {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  private static func hasFontRun(
    in attributed: NSAttributedString,
    near markerSubstring: String,
    matching trait: NSFontDescriptor.SymbolicTraits
  ) -> Bool {
    let fullString = attributed.string as NSString
    let markerRange = fullString.range(of: markerSubstring)
    guard markerRange.location != NSNotFound else { return false }
    let attrs = attributed.attributes(
      at: markerRange.location, effectiveRange: nil)
    guard let font = attrs[.font] as? NSFont else { return false }
    return font.fontDescriptor.symbolicTraits.contains(trait)
  }

  // MARK: - Parameterized tests

  private static let bodyMarkers: [String] = [
    "Heading One", "Heading Two", "Heading Three",
    "Heading Four", "Heading Five", "Heading Six",
    "bold marker text", "italic marker text", "inline code marker",
    "fenced code marker line one", "fenced code marker line two",
    "unordered alpha", "unordered beta", "unordered gamma",
    "ordered uno", "ordered dos", "ordered tres",
    "A blockquote marker.", "Galley link marker",
    "cell one a", "cell one b", "cell two a", "cell two b"
  ]

  @Test(
    "HTML round trip preserves structural invariants",
    arguments: bundledTemplates()
  )
  func roundTripPreservesStructure(template: Template) async throws {
    let html = try await Self.composedHTML(template: template)
    let attributed = try Self.attributedString(fromHTML: html)
    let plain = attributed.string

    #expect(
      attributed.length > 0,
      "Empty NSAttributedString from template \(template.id)")

    for marker in Self.bodyMarkers {
      #expect(
        plain.contains(marker),
        "Template \(template.id) lost \(marker) in clipboard round trip")
    }

    #expect(
      Self.hasFontRun(
        in: attributed, near: "bold marker text", matching: .bold),
      "Template \(template.id) did not preserve bold trait")
    #expect(
      Self.hasFontRun(
        in: attributed, near: "italic marker text", matching: .italic),
      "Template \(template.id) did not preserve italic trait")
    #expect(
      Self.hasFontRun(
        in: attributed,
        near: "inline code marker",
        matching: .monoSpace),
      "Template \(template.id) did not render inline code as monospaced")
    #expect(
      Self.hasFontRun(
        in: attributed,
        near: "fenced code marker line one",
        matching: .monoSpace),
      "Template \(template.id) did not render fenced code as monospaced")

    let linkURL: URL? = {
      let nsString = attributed.string as NSString
      let markerRange = nsString.range(of: "Galley link marker")
      guard markerRange.location != NSNotFound else { return nil }
      let attrs = attributed.attributes(
        at: markerRange.location, effectiveRange: nil)
      if let url = attrs[.link] as? URL { return url }
      if let string = attrs[.link] as? String {
        return URL(string: string)
      }
      return nil
    }()
    #expect(
      linkURL?.absoluteString == "https://galley.example/path",
      """
      Template \(template.id) lost the link href; \
      got \(String(describing: linkURL))
      """)

    let sizes = Self.pointSizes(in: attributed)
    #expect(
      sizes.count >= 2,
      """
      Template \(template.id) collapsed all headings to body size; \
      sizes=\(sizes)
      """)

    let inputBodyLength = Self.fixtureMarkdown.count
    #expect(
      attributed.length >= inputBodyLength / 4,
      """
      Template \(template.id) produced suspiciously short output: \
      \(attributed.length) chars from \(inputBodyLength)-char source
      """)
  }

  @Test(
    "RTF re-export survives the round trip",
    arguments: bundledTemplates()
  )
  func rtfReExportSucceeds(template: Template) async throws {
    let html = try await Self.composedHTML(template: template)
    let attributed = try Self.attributedString(fromHTML: html)

    let rtfRange = NSRange(location: 0, length: attributed.length)
    let rtfData = try #require(
      attributed.rtf(from: rtfRange, documentAttributes: [:]),
      "Template \(template.id) failed to round-trip through RTF")

    #expect(
      rtfData.count > 200,
      """
      Template \(template.id) produced suspiciously small RTF \
      payload (\(rtfData.count) bytes)
      """)

    let prefix = String(data: rtfData.prefix(5), encoding: .ascii)
    #expect(
      prefix == "{\\rtf",
      """
      Template \(template.id) produced non-RTF data; \
      prefix=\(String(describing: prefix))
      """)

    let reparsed = try NSAttributedString(
      data: rtfData,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil)
    #expect(
      reparsed.string.contains("bold marker text"),
      "Template \(template.id) lost body text after RTF re-parse")
  }
}
