import Foundation

/// One of the well-known asset routes shared between the live HTTP
/// server and the in-process URL scheme handler.
///
/// `URL.appending(_ route:)` (below) builds these routes; this enum's
/// `init?(path:)` parses them back. Keeping construction and parsing next
/// to each other prevents the two route shapes from drifting between the
/// renderer side (`TemplateAssetRewriter`) and the resolver side (the
/// Viewer's scheme handler / the server's route table).
public enum PreviewRoute: Sendable, Equatable {
  /// `/template/<id>/<file>` — a file bundled with the named template.
  case templateAsset(id: Template.ID, file: String)
  /// `/preview/<absolute-path>` — a file referenced relative to the
  /// previewed document, carried as an absolute file URL.
  case documentAsset(URL)
  /// `/events/<absolute-path>` — a live-reload (SSE) subscription for the
  /// previewed document, carried as an absolute file URL.
  case events(URL)

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
    case .events: .noStore
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
    } else if let route = Self.parseEvents(path: path) {
      self = route
    } else {
      return nil
    }
  }

  public enum Name: String {
    case template, preview, events
    var prefix: String { "/\(self.rawValue)/" }
  }

  private static func parseTemplate(path: String) -> Self?
  {
    guard let tail = path.tail(prefix: Name.template.prefix)
    else { return nil }

    let parts = tail.split(
      separator: "/",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard parts.count == 2 else { return nil }
    return .templateAsset(
      id: Template.ID(rawValue: parts[0].asString()),
      file: parts[1].asString()
    )
  }

  private static func parsePreview(path: String) -> Self? {
    guard let tail = path.tail(prefix: Name.preview.prefix)
    else { return nil }
    return .documentAsset(URL(fileURLWithPath: "/"+tail))
  }

  private static func parseEvents(path: String) -> Self? {
    guard let tail = path.tail(prefix: Name.events.prefix)
    else { return nil }
    return .events(URL(fileURLWithPath: "/"+tail))
  }
}

extension URL {
  func appending(_ name: PreviewRoute.Name) -> URL {
    appending(path: name.rawValue, directoryHint: .isDirectory)
  }

  public func appending(
    _ route: PreviewRoute,
    directoryHint: URL.DirectoryHint = .notDirectory) -> URL
  {
    switch route {
    case .templateAsset(id: let id, file: let file):
      appending(.template)
        .appending(path: id.rawValue, directoryHint: .isDirectory)
        .appending(path: file, directoryHint: directoryHint)
    case .documentAsset(let url):
      appending(.preview)
        .appending(path: url.safe.path, directoryHint: directoryHint)
    case .events(let url):
      appending(.events)
        .appending(path: url.safe.path, directoryHint: directoryHint)
    }
  }
}
