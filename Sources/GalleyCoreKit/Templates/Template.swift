import Foundation

public protocol TemplateProtocol: Identifiable, Sendable {
  var id: String { get }
  /// User-visible label for menus / pickers. Returning
  /// `LocalizedStringResource` follows Apple's pattern for
  /// domain types (see `CustomLocalizedStringResourceConvertible`)
  /// and decouples the kit from SwiftUI. Translatable cases
  /// (`BuiltInTemplate`'s "Default") use a literal init so the
  /// catalog picks them up; user-defined templates use a runtime
  /// `LocalizationValue` so their filenames don't pollute the
  /// strings catalog.
  var name: LocalizedStringResource { get }
  func loadHTML() throws -> String
  func rewriteAssets(in html: String, origin: URL) -> String
  func resolveAsset(file: String) -> URL?
}

public enum Template: TemplateProtocol,
                      CustomLocalizedStringResourceConvertible
{
  case builtIn(BuiltInTemplate)
  case userDefined(UserTemplate)

  /// `CustomStringConvertible` resolves the localizable name through
  /// the current locale. Used for diagnostic logs and the
  /// `PersistentChoiceValue` envelope's `name` field — neither cares
  /// which locale won.
  public var localizedStringResource: LocalizedStringResource {
    name
  }

  public var id: String {
    switch self {
    case .builtIn(let value): value.id
    case .userDefined(let value): value.id
    }
  }

  public var name: LocalizedStringResource {
    switch self {
    case .builtIn(let value): value.name
    case .userDefined(let value): value.name
    }
  }

  public func loadHTML() throws -> String {
    switch self {
    case .builtIn(let value): try value.loadHTML()
    case .userDefined(let value): try value.loadHTML()
    }
  }

  public func rewriteAssets(in html: String, origin: URL) -> String {
    switch self {
    case .builtIn(let value): value.rewriteAssets(in: html, origin: origin)
    case .userDefined(let value): value.rewriteAssets(in: html, origin: origin)
    }
  }

  public func resolveAsset(file: String) -> URL? {
    switch self {
    case .builtIn(let value): value.resolveAsset(file: file)
    case .userDefined(let value): value.resolveAsset(file: file)
    }
  }
}

public extension Template {
  static var `default`: Template { .builtIn(.shared) }
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

public extension TemplateProtocol {
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
    return ComposedPreview(
      html: context.substitute(into: processed),
      baseURL: origin.appendingPreview(documentURL))
  }
}
