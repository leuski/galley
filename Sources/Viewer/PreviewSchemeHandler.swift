import Foundation
import GalleyCoreKit
import WebKit
import os
import ALFoundation

let bundleIdentifier = Bundle.main.bundleIdentifier ?? "net.leuski.galley"
let keyPrefix = bundleIdentifier

/// Custom URL scheme that lets the Viewer's WebView load template
/// assets (CSS, fonts, images) and document-relative files. The
/// scheme mirrors the live HTTP server's routing — `/template/<id>/…`
/// for template-bundled assets, `/preview/<absolute-path>` for files
/// referenced relative to the previewed document — so the existing
/// `Template.rewriteAssets(...)` rewriting logic produces URLs that
/// resolve correctly here too.
///
/// Origin is `x-galley://local`. The Viewer sets the WebPage's
/// `baseURL` to the same origin so any unrewritten relative URLs
/// (e.g. those in inline `<img>` markup the document author wrote)
/// flow through the handler as well.
///
/// Distinct from `galley://`, which is reserved for the cross-app
/// launch URL handled by LaunchServices in `ViewerAppDelegate`.
/// Two layers, two names — avoids any chance of `application(_:open:)`
/// receiving an internal asset URL and avoids LaunchServices
/// re-routing an unclaimed in-WebView navigation back into the app.

@MainActor
struct PreviewSchemeHandler: URLSchemeHandler {
  static let scheme = URLScheme("x-galley") !! "Should not happen"
  static let originURL: URL = "x-galley://local"

  /// Reads the active template at request time. Avoids stale state
  /// when the user switches templates: the next asset request picks
  /// up the new directory.
  let templateProvider: @MainActor @Sendable () -> Template

  private static let logger = Logger(
    subsystem: bundleIdentifier,
    category: "PreviewSchemeHandler")

  nonisolated
  func reply(
    for request: URLRequest
  ) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task { @MainActor in
        do {
          let (data, mime) = try Self.resolve(
            request: request,
            templateProvider: templateProvider)
          guard let url = request.url else {
            throw URLError(.badURL)
          }
          let response = URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: nil)
          continuation.yield(.response(response))
          continuation.yield(.data(data))
          continuation.finish()
        } catch {
          Self.logger.warning("""
            asset load failed for \
            \(request.url?.absoluteString ?? "?", privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Shared resolution used by both the SwiftUI `URLSchemeHandler`
  /// path (for the visible `WebPage`) and the classic
  /// `WKURLSchemeHandler` adapter used by the offscreen print
  /// `WKWebView`. The print path can't reach the SwiftUI handler
  /// because the two protocols don't compose, but they need to
  /// resolve `x-galley://local/...` URLs identically.
  @MainActor
  static func resolve(
    request: URLRequest,
    templateProvider: () -> Template
  ) throws -> (Data, String) {
    guard let url = request.url else { throw URLError(.badURL) }
    guard let route = PreviewRoute(path: url.path) else {
      throw URLError(.unsupportedURL)
    }
    let assetURL = try resolveAssetURL(
      for: route, templateProvider: templateProvider)
    let data = try Data(contentsOf: assetURL)
    return (data, MIMETypes.mimeType(for: assetURL))
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

/// Adapter that exposes the same asset resolution to a classic
/// `WKWebView`. Used by the offscreen print/export web view, which
/// can't accept a SwiftUI `URLSchemeHandler` (different protocol).
@MainActor
final class ClassicPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
  private let templateProvider: @MainActor @Sendable () -> Template

  init(templateProvider: @escaping @MainActor @Sendable () -> Template) {
    self.templateProvider = templateProvider
    super.init()
  }

  func webView(
    _ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask
  ) {
    do {
      let (data, mime) = try PreviewSchemeHandler.resolve(
        request: urlSchemeTask.request,
        templateProvider: templateProvider)
      guard let url = urlSchemeTask.request.url else {
        throw URLError(.badURL)
      }
      let response = URLResponse(
        url: url,
        mimeType: mime,
        expectedContentLength: data.count,
        textEncodingName: nil)
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(
    _ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask
  ) {
    // No async work to cancel — resolve runs synchronously.
  }
}
