import Foundation
import GalleyCoreKit
import WebKit
import os
import ALFoundation

/// SwiftUI-flavored `URLSchemeHandler` for the Viewer's visible
/// `WebPage`. The actual asset resolution lives in
/// `GalleyCoreKit.PreviewScheme.resolve` and is shared with the
/// offscreen print web view and the QuickLook preview extension via
/// `ClassicPreviewSchemeHandler`.
///
/// Origin is `PreviewScheme.originURL` (`x-galley://local`). The
/// Viewer sets the WebPage's `baseURL` to the document's
/// `/preview/<absolute-path>` URL under that origin so unrewritten
/// relative references in the rendered body (e.g. an `image.png`
/// sibling of the document) resolve through the handler's
/// `documentAsset` route. Templates that include
/// `<base href="#BASE#">` override this with the same value via
/// `PlaceholderContext.substitute`; templates without it fall back
/// to the page baseURL and end up at the same place.
@MainActor
struct PreviewSchemeHandler: URLSchemeHandler {
  static let scheme = URLScheme(PreviewScheme.name)
  !! "Failed to make URLScheme for \(PreviewScheme.name)"
  static var originURL: URL { PreviewScheme.originURL }

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
          let (data, mime) = try PreviewScheme.resolve(
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
          Self.logAssetLoadFailed(request: request, error: error)
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
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
