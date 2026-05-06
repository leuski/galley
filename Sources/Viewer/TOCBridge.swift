import Foundation
import GalleyCoreKit
import os
import WebKit

/// Receives `{ items: [{ id, level, text }, ...] }` messages from a
/// user script that walks the rendered document's `<h1>…<h6>` tree
/// after each load. The injected script also assigns synthetic ids
/// to headings that lack one, so the sidebar can target every entry
/// via `getElementById` regardless of which renderer produced the
/// HTML (swift-markdown / pandoc / cmark-gfm / multimarkdown / etc.).
@MainActor
final class TOCBridge: NSObject, WKScriptMessageHandler {
  static let messageName = "toc"

  /// Walk `<h1>…<h6>` once per load, slugify text into a unique id
  /// for any heading without one, and post the flat list back. Pre-
  /// seeds the slug-uniqueness set with every existing `id` on the
  /// page so renderer-supplied anchors aren't shadowed by ours.
  static let userScript: String = """
    (function() {
      function slugify(text, used) {
        var base = text.trim().toLowerCase()
          .replace(/[^a-z0-9\\s-]/g, '')
          .replace(/\\s+/g, '-')
          .replace(/-+/g, '-')
          .replace(/^-|-$/g, '');
        if (!base) base = 'section';
        var id = base, counter = 1;
        while (used.has(id)) {
          counter += 1;
          id = base + '-' + counter;
        }
        used.add(id);
        return id;
      }
      var used = new Set();
      document.querySelectorAll('[id]').forEach(function(el) {
        used.add(el.id);
      });
      var nodes = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
      var items = [];
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        var text = (node.textContent || '').replace(/\\s+/g, ' ').trim();
        if (!text) continue;
        if (!node.id) {
          node.id = slugify(text, used);
        }
        items.push({
          id: node.id,
          level: parseInt(node.tagName.substring(1), 10),
          text: text
        });
      }
      window.webkit.messageHandlers.\(messageName).postMessage(
        { items: items });
    })();
    """

  /// Set by the owning DocumentModel; receives the freshly-extracted
  /// heading list every time the page loads.
  var onHeadings: (([TOCEntry]) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "TOCBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let items = body["items"] as? [[String: Any]]
    else {
      logMalformedMessage(message.body)
      return
    }
    let headings: [TOCEntry] = items.compactMap { entry in
      guard let id = entry["id"] as? String,
            let text = entry["text"] as? String,
            let level = entry["level"] as? Int
      else { return nil }
      return TOCEntry(id: id, level: level, text: text)
    }
    onHeadings?(headings)
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed toc message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
