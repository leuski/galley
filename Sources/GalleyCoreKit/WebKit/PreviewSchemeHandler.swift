import Foundation
import WebKit
import OSLog

/// Custom URL scheme that lets an in-process `WKWebView` resolve the
/// same template-asset and document-relative URLs the HTTP server
/// produces. The HTML built via `template.rewriteAssets(in:origin:)`
/// + `PlaceholderContext.substitute(into:)` with `origin` set to
/// `originURL` will reference assets at `x-galley://local/template/<id>/<file>`
/// and `x-galley://local/preview/<absolute-path>`. Both shapes are
/// handled by `ClassicPreviewSchemeHandler` below by mapping to
/// `Template.resolveAsset(file:)` and direct filesystem reads.
///
/// Distinct from `galley://`, which is reserved for cross-app launch
/// URLs handled by LaunchServices.
public enum PreviewScheme {
  public static let name = "x-galley"
  public static let originURL: URL = "x-galley://local"

  /// Shared resolution used by every in-process consumer:
  /// the Viewer's visible `WebPage`, its offscreen print/export
  /// `WKWebView`, and the QuickLook extension's fallback render.
  @MainActor
  public static func resolve(
    request: URLRequest,
    templateProvider: () -> Template
  ) throws -> ResolvedBytes {
    guard let url = request.url else { throw URLError(.badURL) }
    guard let route = PreviewRoute(path: url.path) else {
      throw URLError(.unsupportedURL)
    }
    let assetURL = try resolveAssetURL(
      for: route, templateProvider: templateProvider)
    let data = try Data(contentsOf: assetURL)
    // The route kind decides cacheability: template assets are static (bounded
    // cache), document-relative siblings are live-edited (`no-store`).
    return ResolvedBytes(
      data: data,
      mime: MIMETypes.mimeType(for: assetURL),
      cache: route.cachePolicy)
  }

  @MainActor
  private static func resolveAssetURL(
    for route: PreviewRoute,
    templateProvider: () -> Template
  ) throws -> URL {
    switch route {
    case .templateAsset(let id, let file):
      let template = templateProvider()
      guard template.id == id,
            let assetURL = template.resolveAsset(file: file)
      else { throw URLError(.fileDoesNotExist) }
      return assetURL
    case .documentAsset(let absolutePath):
      return URL(fileURLWithPath: absolutePath)
    }
  }
}

/// Adapter that exposes `PreviewScheme.resolve` to a classic
/// `WKWebView`. SwiftUI's `URLSchemeHandler` (used by `WebPage`) is a
/// distinct protocol, so the Viewer's visible preview keeps its own
/// thin wrapper; this class is what the offscreen print web view and
/// the QuickLook preview extension install.
@MainActor
public final class ClassicPreviewSchemeHandler:
  NSObject, WKURLSchemeHandler
{
  private let templateProvider: @MainActor @Sendable () -> Template

  private static let logger = Logger(
    subsystem: bundleIdentifier,
    category: "PreviewSchemeHandler")

  public init(
    templateProvider: @escaping @MainActor @Sendable () -> Template
  ) {
    self.templateProvider = templateProvider
    super.init()
  }

  public func webView(
    _ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask
  ) {
    do {
      let resolved = try PreviewScheme.resolve(
        request: urlSchemeTask.request,
        templateProvider: templateProvider)
      // An `HTTPURLResponse` (not a bare `URLResponse`) so we can carry the
      // resolver's `Cache-Control` — lets WebKit reuse static template assets
      // instead of re-resolving them on every navigation.
      guard let url = urlSchemeTask.request.url,
            let response = HTTPURLResponse(
              url: url,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: [
                "Content-Type": resolved.mime,
                "Content-Length": "\(resolved.data.count)",
                "Cache-Control": resolved.cache.cacheControl
              ])
      else {
        throw URLError(.badURL)
      }
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(resolved.data)
      urlSchemeTask.didFinish()
    } catch {
      Self.logAssetLoadFailed(
        request: urlSchemeTask.request, error: error)
      urlSchemeTask.didFailWithError(error)
    }
  }

  public func webView(
    _ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask
  ) {
    // No async work to cancel — resolve runs synchronously.
  }

  private static func logAssetLoadFailed(
    request: URLRequest, error: any Error
  ) {
    logger.warning("""
      asset load failed for \
      \(request.url?.absoluteString ?? "?", privacy: .public): \
      \(error.localizedDescription, privacy: .public)
      """)
  }
}
