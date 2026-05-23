#if os(macOS)
import AppKit
#endif
import Foundation
import GalleyCoreKit
import WebKit
import os
import ALFoundation

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

  /// Optional callback for external URLs (non-markdown local files,
  /// http/https, mailto, etc.). When set, the bridge delegates the
  /// open to the host. On macOS the bridge falls back to
  /// `NSWorkspace.shared.open` when this is `nil` (the historical
  /// behavior); on visionOS / iOS the host MUST install this — the
  /// fallback is `#if`'d out because `NSWorkspace` is unavailable.
  var onExternalURL: ((URL) -> Void)?

  /// Optional callback for `finder://…` reveal links. Macros to
  /// "select this path in Finder". macOS-only convention; the
  /// callback is wired in only on macOS. visionOS / iOS hosts will
  /// never see this fire.
  var onFinderReveal: ((URL) -> Void)?

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

    if target.scheme == Self.finderScheme {
      // Author-declared "reveal in Finder" link. Swap to a file URL on
      // the same path and select it — Finder opens the parent (which
      // may be inside a package) with the target highlighted. This is
      // the macOS equivalent of "Show Package Contents".
      let fileURL = URL(
        fileURLWithPath: target.path,
        relativeTo: Bundle.main.bundleURL
      ).safe
      #if os(macOS)
      if let onFinderReveal {
        onFinderReveal(fileURL)
      } else {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
      }
      #else
      // visionOS / iOS: no Finder. Hand off as an external URL if the
      // host installed a callback; otherwise silently drop — there's
      // no graceful platform fallback for a "reveal in Finder" link.
      onExternalURL?(fileURL)
      #endif
      return
    }

    if target.isFileURL,
       MarkdownFileTypes.extensions.contains(
         target.pathExtension.lowercased())
    {
      // Markdown — prefer in-window navigation (browser style) when
      // the host has wired the callback. Fall back to opening a new
      // Viewer document via NSDocumentController (macOS only).
      if let onMarkdownLink {
        onMarkdownLink(target)
        return
      }
      #if os(macOS)
      NSDocumentController.shared.openDocument(
        withContentsOf: target,
        display: true
      ) { [weak self] _, _, error in
        if let error {
          self?.logOpenDocumentFailed(target: target, error: error)
        }
      }
      #else
      // visionOS / iOS: no NSDocumentController. Hosts that want
      // markdown links to spawn a new window MUST install
      // `onMarkdownLink`. Reaching here is a host-wiring bug.
      logger.warning("""
        Markdown link with no onMarkdownLink callback: \
        \(target.absoluteString, privacy: .public)
        """)
      #endif
      return
    }

    // External URL or non-markdown local file.
    if let onExternalURL {
      onExternalURL(target)
      return
    }
    #if os(macOS)
    // macOS fallback for hosts that haven't wired onExternalURL —
    // let LaunchServices pick the right app.
    let opened = NSWorkspace.shared.open(target)
    if !opened {
      logWorkspaceOpenFailed(target)
    }
    #else
    logger.warning("""
      External URL with no onExternalURL callback: \
      \(target.absoluteString, privacy: .public)
      """)
    #endif
  }

  /// Custom URL scheme that means "reveal this path in Finder rather
  /// than open it." `finder:///Applications/Galley.app/Contents/...`
  /// is a regular file path; the scheme just flips the dispatch.
  private static let finderScheme = "finder"

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

  #if os(macOS)
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
  #endif

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
    let baseDir = documentURL.parent

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
    if documentURL.isFileURL {
      return URL(fileURLWithPath: decoded, relativeTo: baseDir).safe
    }
    // Remote document: resolve the href against the remote base so a
    // relative `../foo.md` stays remote. `URL(string:relativeTo:)`
    // preserves the scheme/host on the base; `absoluteURL`
    // flattens the resolution into a self-contained URL.
    return URL(string: path, relativeTo: baseDir)?.absoluteURL
  }
}
