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
  /// `request.path` for the HTTP server). Percent-decoded.
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
    let rawID = String(tail[..<slash])
    let rawFile = String(tail[tail.index(after: slash)...])
    let id = rawID.removingPercentEncoding ?? rawID
    let file = rawFile.removingPercentEncoding ?? rawFile
    return .templateAsset(id: Template.ID(rawValue: id), file: file)
  }

  private static func parsePreview(path: String) -> Self? {
    let prefix = "/\(RouteNames.preview)"
    guard path.hasPrefix(prefix) else { return nil }
    var tail = String(path.dropFirst(prefix.count))
    if !tail.hasPrefix("/") { tail = "/" + tail }
    let decoded = tail.removingPercentEncoding ?? tail
    return .documentAsset(absolutePath: decoded)
  }
}
