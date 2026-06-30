import Foundation

/// One of the well-known asset routes shared between the live HTTP
/// server and the in-process URL scheme handler.
///
/// `URL.appendingPreview(_:)` (in `String+URL.swift`) build these
/// routes; this enum parses them back. Keeping construction and
/// parsing next to each other prevents the two route shapes from
/// drifting between the renderer side (`TemplateAssetRewriter`) and
/// the resolver side (the Viewer's scheme handler / the server's
/// route table).
public enum PreviewRoute: Sendable, Equatable {
  /// `/template/<id>/<file>` — a file bundled with the named template.
  case templateAsset(id: Template.ID, file: String)
  /// `/preview/<absolute-path>` — a file referenced relative to the
  /// previewed document, expressed as an absolute filesystem path.
  case documentAsset(absolutePath: String)

  /// Cache window for template assets — long enough to stop per-navigation
  /// refetches (notably over the AVP tunnel), short enough that editing a
  /// custom template shows up without a hard reload.
  public static let templateAssetMaxAge = 300

  /// How a response for this route may be cached. Template assets are static
  /// per template — but a user can edit a custom template's files, so they
  /// get a bounded window rather than `.immutable`. Document-relative assets
  /// are live-edited siblings of the previewed file, so they are never stored.
  public var cachePolicy: CachePolicy {
    switch self {
    case .templateAsset: .maxAge(seconds: Self.templateAssetMaxAge)
    case .documentAsset: .noStore
    }
  }

  /// Parse a URL path (`url.path` for the scheme handler,
  /// `request.path` for the HTTP server). Both inputs are already
  /// percent-decoded (`URL.path` / `URLComponents.path`), so the parser
  /// does not decode again.
  public init?(path: String) {
    if let route = Self.parseTemplate(path: path) {
      self = route
    } else if let route = Self.parsePreview(path: path) {
      self = route
    } else {
      return nil
    }
  }

  private static func parseTemplate(path: String) -> Self? {
    let prefix = "/\(RouteNames.template)/"
    guard path.hasPrefix(prefix) else { return nil }
    let tail = path.dropFirst(prefix.count)
    guard let slash = tail.firstIndex(of: "/") else { return nil }
    let id = String(tail[..<slash])
    let file = String(tail[tail.index(after: slash)...])
    return .templateAsset(id: Template.ID(rawValue: id), file: file)
  }

  private static func parsePreview(path: String) -> Self? {
    let prefix = "/\(RouteNames.preview)"
    // Match the full `/preview/` segment so the name can't collide with the
    // prefix of a longer route; strip the bare prefix so the tail keeps its
    // leading slash and reads as an absolute filesystem path.
    guard path.hasPrefix(prefix + "/") else { return nil }
    return .documentAsset(absolutePath: String(path.dropFirst(prefix.count)))
  }
}
