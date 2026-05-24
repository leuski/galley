import Foundation

/// Custom URL scheme that the AVP WebView uses for every navigation
/// and sub-resource fetch when displaying Mac-hosted documents.
/// Requests on this scheme are intercepted by a `URLSchemeHandler`
/// and tunneled to the Mac via `KosmosCore.ProxyHTTPRequest`.
///
/// Public so both sides (Mac → URL builders, AVP → scheme handler)
/// agree on the name without a magic string.
public enum KosmosTunnelScheme {
  /// Bare scheme name (no `://`). `galley` rather than `x-galley`
  /// because it's the user-facing scheme appearing in the WebView
  /// origin; the `x-galley` scheme is reserved for the Mac/Quicklook
  /// in-process template-asset resolver.
  public static let name = "galley"

  /// Canonical request prefix for document/asset paths — every
  /// tunneled URL begins with `galley://preview/<absolute-path>`.
  public static let previewURLPrefix = "\(name)://preview"

  /// Construct a tunnel URL for a document or asset at a POSIX path.
  /// `path` must begin with `/`. Returns nil only on malformed input.
  ///
  /// Note: the path is percent-encoded for URL safety; the AVP
  /// scheme handler unwinds it back to a Mac-relative path when
  /// constructing the `ProxyHTTPRequest`'s `urlPath` field.
  public static func previewURL(forFile path: String) -> URL? {
    guard path.hasPrefix("/") else { return nil }
    let encoded = path.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed) ?? path
    return URL(string: "\(previewURLPrefix)\(encoded)")
  }
}
