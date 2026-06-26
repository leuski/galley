import Foundation

public extension URL {

  /// Self with any query and fragment stripped. Pure; safe on any URL.
  var withoutQueryOrFragment: URL {
    guard var components = URLComponents(
      url: self, resolvingAgainstBaseURL: false)
    else { return self }
    components.query = nil
    components.fragment = nil
    return components.url ?? self
  }

  /// Tokens a document window advertises via SwiftUI
  /// `handlesExternalEvents(preferring:)` so a repeat-open of the same
  /// document routes back to the window already showing it instead of
  /// spawning a duplicate. Match tokens are prefix-matched against the
  /// incoming URL's `absoluteString`, so:
  ///
  ///   - the query is dropped, so `galley://p?line=2` still routes to
  ///     the window showing `galley://p`;
  ///   - a standardized file-URL form is added when it differs from
  ///     the original (symlinked or `..`-laden paths);
  ///   - the `galley://` form is added because re-opens arrive in that
  ///     scheme (BBEdit's preview script, in-process menu opens) while
  ///     the window's bound value is always a `file://` URL.
  ///
  /// Returns an empty array for a window with no bound URL (the empty
  /// bootstrap window), which then competes only as an `allowing`
  /// catch-all.
  var galleyPreferringTokens: Set<String> {
    [
      self,
      isFileURL ? standardizedFileURL : nil,
      isFileURL ? GalleyViewerRequestActivity(
        url: standardizedFileURL).url : nil
    ]
      .compactMap { url in url?.withoutQueryOrFragment.absoluteString }
      .filter { path in !path.isEmpty }
      .asSet()
  }

  /// Resolves the kit framework's bundled templates folder.
  ///
  /// The bundled templates ship inside a `Templates.bundle` directory
  /// because Xcode 16's synchronized root groups otherwise flatten
  /// resource directory structure when copying — a `.bundle`-suffixed
  /// folder is treated as an opaque wrapper and copied whole. Inside
  /// the wrapper we keep one folder per template (`Default/`,
  /// future `Tufte/`, etc.) using the same folder shape user
  /// templates use.
  static let bundleTemplatesDirectoryURL: URL = {
    Bundle.galleyCoreKit.url(
      forResource: "Templates", withExtension: "bundle")
    !! "GalleyCoreKit bundle missing Templates.bundle wrapper"
  }()
}

extension URL {
  public var galleyPreview: URL {
    appending(path: RouteNames.preview)
  }

  /// Construct a tunnel URL for a document or asset at a POSIX path.
  /// `path` must begin with `/`. Returns nil only on malformed input.
  ///
  /// `URL.appending(path:)` percent-encodes its argument, so the
  /// input is the raw filesystem path — never `percentEncodedForPath`,
  /// or `%` itself ends up as `%25` on the wire.
  public func galleyPreviewURL(forFile path: String) -> URL? {
    guard path.hasPrefix("/") else { return nil }
    return galleyPreview.appending(path: path)
  }

  public func galleyTemplate(id: GalleyCoreKit.Template.ID) -> URL {
    appending(path: RouteNames.template).appending(path: id.rawValue)
  }

  /// `<self>/preview` — the route prefix for previewed documents.
  /// Pass `documentPath` to point at a specific document.
  public func appendingPreview(_ documentURL: URL) -> URL {
    galleyPreview.appending(path: documentURL.safe.path)
  }
}
