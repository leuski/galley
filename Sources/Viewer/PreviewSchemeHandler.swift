import Foundation
import GalleyCoreKit
import WebKit
import os
import ALFoundation

let keyPrefix = bundleIdentifier

/// SwiftUI-flavored `URLSchemeHandler` for the Viewer's visible
/// `WebPage`. The actual asset resolution lives in
/// `GalleyCoreKit.PreviewScheme.resolve` and is shared with the
/// offscreen print web view and the QuickLook preview extension via
/// `ClassicPreviewSchemeHandler`.
///
/// Origin is `PreviewScheme.originURL` (`x-galley://local`). The
/// Viewer sets the WebPage's `baseURL` to the same origin so any
/// unrewritten relative URLs (e.g. those in inline `<img>` markup the
/// document author wrote) flow through the handler as well.
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
