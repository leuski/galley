import Foundation

/// One template — bundled or user-installed, file-shape or folder-shape,
/// they all collapse to the same struct. The kit ships a `Default`
/// template inside its bundle; users drop additional folders/files into
/// `~/Library/Application Support/.../Templates/`. `TemplateStore` scans
/// an ordered list of source directories and stamps each entry's `id`
/// with `<source-index>.<name>` so collisions across sources never happen
/// (a user template named "Default" coexists with the bundled "Default"
/// because their source indices differ).
public struct Template: Sendable, Identifiable,
                        CustomLocalizedStringResourceConvertible
{
  public let id: String
  /// User-visible label. Bundled templates get a literal
  /// `LocalizedStringResource` so Xcode's catalog extraction picks the
  /// label up; user templates wrap their filename in a runtime
  /// `LocalizationValue` so filenames stay out of the strings catalog.
  public let name: LocalizedStringResource
  /// Where to resolve sibling assets from. For folder templates this is
  /// the template's own folder; for file templates (BBEdit convention)
  /// this is the *parent* directory the file sits in, which is shared
  /// with sibling templates in the same source.
  public let directoryURL: URL
  /// The HTML file itself.
  public let htmlURL: URL
  /// Index of the source directory this template came from, in
  /// `TemplateStore.directoryURLs`. Used for menu sectioning so
  /// bundled and user templates render in distinct groups without the
  /// store having to expose source identity any other way.
  public let sourceIndex: Int

  public init(
    id: String,
    name: LocalizedStringResource,
    directoryURL: URL,
    htmlURL: URL,
    sourceIndex: Int
  ) {
    self.id = id
    self.name = name
    self.directoryURL = directoryURL
    self.htmlURL = htmlURL
    self.sourceIndex = sourceIndex
  }

  public var localizedStringResource: LocalizedStringResource { name }

  public func loadHTML() throws -> String {
    try String(contentsOf: htmlURL, encoding: .utf8)
  }

  public func rewriteAssets(in html: String, origin: URL) -> String {
    TemplateAssetRewriter(id: id, origin: origin).rewriteAssets(in: html)
  }

  public func resolveAsset(file: String) -> URL? {
    let directoryURL = self.directoryURL.safe
    let candidate = (directoryURL / file).safe
    return candidate.path.hasPrefix(directoryURL.path.appendingSlash)
      ? candidate : nil
  }
}

public extension Template {
  /// Fallback for callers that need a known-good template without a
  /// store handy (e.g. the Server's renderer-provider closure when
  /// the template choice has been GC'd). Resolves the bundled
  /// "Default" entry directly off the kit's bundle resources.
  static let bundledDefault: Template = {
    guard let template = Template(
      sourceURL: .bundleTemplatesDirectoryURL,
      sourceIndex: TemplateStore.bundleSourceIndex,
      name: "Default.html",
      nameResource: LocalizedStringResource(
        "Default", bundle: .galleyCoreKit))
    else {
      fatalError("GalleyCoreKit bundle missing Templates.bundle/Default.html")
    }
    return template
  }()

  /// Convenience used by callers that previously wrote `.default`.
  /// Resolves to `bundledDefault` so the static fallback still works
  /// without depending on `TemplateStore`.
  static var `default`: Template { .bundledDefault }
}

extension Template: ChoiceValueProtocol {
  public typealias PersistentID = String
  public var persistentID: String { id }
}

/// Result of composing a preview page. Pairs the final HTML with the
/// `baseURL` the consuming web view must load it under, so callers
/// can't accidentally pair the right HTML with the wrong base — the
/// failure mode that previously broke document-relative images for
/// every template that lacked a `<base href="#BASE#">` tag.
public struct ComposedPreview: Sendable {
  public let html: String
  public let baseURL: URL
}

public extension Template {
  /// Canonical recipe for producing a preview page, shared by the
  /// Viewer's live page, its print/export pipeline, and Quick Look's
  /// in-process fallback.
  ///
  /// Loads the template, rewrites its asset references through
  /// `origin`, substitutes placeholders with the document content,
  /// and returns the HTML alongside the page `baseURL` the consumer
  /// must load it under. The base mirrors the document's
  /// `/preview/<absolute-path>` URL so unrewritten relative
  /// references in the rendered body resolve through the scheme
  /// handler's `documentAsset` route. Templates that ship
  /// `<base href="#BASE#">` will override this with the same value
  /// via `PlaceholderContext.substitute`; templates that don't fall
  /// back to the page base and end up at the same place.
  ///
  /// Asset rewriting runs *before* placeholder substitution so the
  /// rewriter only touches template-authored URLs and leaves URLs in
  /// the rendered document body alone — reversing the order routes
  /// document-relative `<img>`/`<link>` references through the
  /// `/template/<id>/` namespace and breaks them.
  func composeHTML(
    documentContent: String,
    documentURL: URL,
    origin: URL
  ) throws -> ComposedPreview {
    let templateHTML = try loadHTML()
    let processed = rewriteAssets(in: templateHTML, origin: origin)
    let context = PlaceholderContext(
      documentContent: documentContent,
      documentURL: documentURL,
      origin: origin)
    let substituted = context.substitute(into: processed)
    return ComposedPreview(
      html: injectingTemplateIDMeta(into: substituted),
      baseURL: origin.appendingPreview(documentURL))
  }

  /// Inserts `<meta name="galley-template-id" content="...">` just
  /// before `</head>` so the Viewer's `BackgroundColorBridge` can
  /// attribute every post to the template that's *actually* painted
  /// in the WebView at the moment of the post — not whichever
  /// template happens to be selected by the time the message
  /// reaches Swift. The two diverge briefly whenever the user
  /// switches templates faster than WebKit can reload, and the gap
  /// was previously enough to poison the new template's cached
  /// background color with a stale post from the outgoing page.
  ///
  /// Falls back to prepending the meta when the template ships no
  /// `<head>` — orphan metas are tolerated by every renderer Galley
  /// targets, and we still need the id present somewhere in the DOM
  /// for the JS reader to find via `document.querySelector`.
  private func injectingTemplateIDMeta(into html: String) -> String {
    let meta = """
      <meta name="galley-template-id" content="\(id.htmlAttributeEscaped)">
      """
    if let range = html.range(
      of: "</head>", options: [.caseInsensitive]) {
      return html.replacingCharacters(
        in: range, with: meta + "</head>")
    }
    return meta + html
  }
}
