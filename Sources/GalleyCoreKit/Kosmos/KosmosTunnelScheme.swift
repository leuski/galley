import ALFoundation
import Foundation

/// Custom URL scheme that the AVP WebView uses for every navigation
/// and sub-resource fetch when displaying Mac-hosted documents.
/// Requests on this scheme are intercepted by a `URLSchemeHandler`
/// and tunneled to the Mac via `KosmosCore.ProxyHTTPRequest`.
///
/// Mirrors `PreviewScheme` in shape (sentinel host, `/<route>/<path>`
/// layout), but uses `galley://local` — the user-facing scheme that
/// appears in the WebView origin. The `x-galley` scheme is reserved
/// for the Mac/Quicklook in-process template-asset resolver.
///
/// - Document URL:  `galley://local/preview/<absolute-fs-path>`
/// - Template URL:  `galley://local/template/<id>/<file>`
/// - SSE events:    `galley://local/events/<absolute-fs-path>`
///
/// The AVP scheme handler builds `ProxyHTTPRequest.urlPath` from
/// `URLComponents.percentEncodedPath` verbatim; no host splicing.
public enum KosmosTunnelScheme {
  public static let name = "galley"

  /// `galley://local` — the scheme origin (no trailing slash). Sent
  /// as `X-Galley-Origin` on every tunneled request so the Mac's
  /// `templateOriginURL` returns this when composing `<base href>`
  /// in rendered HTML. With base href on the same scheme, every
  /// sub-resource fetch (CSS, JS, images, SSE) tunnels back through
  /// the scheme handler instead of escaping to `http://127.0.0.1`.
  public static let originURL: URL = "galley://local"

  /// Construct a tunnel URL for a document or asset at a POSIX path.
  /// `path` must begin with `/`. Returns nil only on malformed input.
  public static func previewURL(forFile path: String) -> URL? {
    guard path.hasPrefix("/") else { return nil }
    return originURL.galleyPreview
      .appendingPathComponent(path.percentEncodedForPath)
  }
}
