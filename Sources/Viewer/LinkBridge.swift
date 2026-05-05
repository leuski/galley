import AppKit
import Foundation
import GalleyCoreKit
import WebKit
import os

/// Handles plain-click on `<a href>` elements inside the rendered
/// preview: resolves relative paths against the current document, and
/// opens the target. Markdown files open as new Viewer documents
/// (which then participate in macOS native window tabbing); everything
/// else is handed off to LaunchServices.
@MainActor
final class LinkBridge: NSObject, WKScriptMessageHandler {
  /// JS message handler name. JS calls
  /// `window.webkit.messageHandlers.linkclick.postMessage({ href })`.
  static let messageName = "linkclick"

  /// The document being previewed. Resolves relative hrefs.
  var documentURL: URL?

  /// Optional callback for in-app markdown navigation. When set, a
  /// click on a `.md` link calls this with the resolved URL instead
  /// of opening a new Viewer document. Lets the host re-point the
  /// current WebView (browser-style) rather than spawning a window.
  var onMarkdownLink: ((URL) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "LinkBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let href = body["href"] as? String
    else {
      logMalformedMessage(message.body)
      return
    }
    handle(href: href)
  }

  private func handle(href: String) {
    guard let target = resolve(href: href) else {
      logUnresolvableHref(href)
      return
    }
    logOpeningLink(target)

    if target.isFileURL,
       MarkdownFileTypes.extensions.contains(
         target.pathExtension.lowercased())
    {
      // Markdown — prefer in-window navigation (browser style) when
      // the host has wired the callback. Fall back to opening a new
      // Viewer document via NSDocumentController.
      if let onMarkdownLink {
        onMarkdownLink(target)
      } else {
        NSDocumentController.shared.openDocument(
          withContentsOf: target,
          display: true
        ) { [weak self] _, _, error in
          if let error {
            self?.logOpenDocumentFailed(target: target, error: error)
          }
        }
      }
    } else {
      // External URL or non-markdown local file — let LaunchServices
      // pick the right app.
      let opened = NSWorkspace.shared.open(target)
      if !opened {
        logWorkspaceOpenFailed(target)
      }
    }
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning(
      "Ignoring malformed link message: \(String(describing: body))")
  }

  private func logUnresolvableHref(_ href: String) {
    logger.warning("Could not resolve link href: \(href, privacy: .public)")
  }

  private func logOpeningLink(_ target: URL) {
    logger.notice("Opening link: \(target.absoluteString, privacy: .public)")
  }

  private func logOpenDocumentFailed(target: URL, error: any Error) {
    logger.error("""
      openDocument failed for \(target.path, privacy: .public): \
      \(error.localizedDescription, privacy: .public)
      """)
  }

  private func logWorkspaceOpenFailed(_ target: URL) {
    logger.error("""
      NSWorkspace.open returned false for \
      \(target.absoluteString, privacy: .public)
      """)
  }

  /// Resolve an `href` from the document against `documentURL`'s
  /// directory. Returns the resulting URL, or nil if the input is
  /// nonsensical.
  private func resolve(href: String) -> URL? {
    if let absolute = URL(string: href),
       let scheme = absolute.scheme, !scheme.isEmpty,
       absolute.scheme != "file" || href.hasPrefix("file:")
    {
      // Absolute URL with an explicit scheme (https://, mailto:, etc.).
      return absolute
    }

    guard let documentURL else { return nil }
    let baseDir = documentURL.deletingLastPathComponent()

    // Strip a query/fragment for path resolution; webkit handles them
    // again on the loaded doc (we only care about which file to open).
    let path: String
    if let pivot = href.firstIndex(where: { $0 == "?" || $0 == "#" }) {
      path = String(href[..<pivot])
    } else {
      path = href
    }
    if path.isEmpty { return nil }

    let decoded = path.removingPercentEncoding ?? path
    if decoded.hasPrefix("/") {
      return URL(fileURLWithPath: decoded).standardized
    }
    return URL(fileURLWithPath: decoded, relativeTo: baseDir)
      .standardized
  }
}
