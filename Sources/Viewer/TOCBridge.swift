import Foundation
import GalleyCoreKit
import os
import WebKit

/// Receives two kinds of messages from a user script that walks the
/// rendered document's `<h1>…<h6>` tree after each load:
///
/// - `{ items: [{ id, level, text }, ...] }` — the heading list,
///   posted once per load. The script assigns synthetic ids to
///   headings that lack one, so the sidebar can target every entry
///   via `getElementById` regardless of which renderer produced the
///   HTML (swift-markdown / pandoc / cmark-gfm / multimarkdown / etc.).
/// - `{ activeId: <String?> }` — the currently-active heading,
///   recomputed on scroll. "Active" is the last heading whose top
///   edge has scrolled past a threshold near the top of the
///   viewport — the convention every doc site uses to track the
///   reader's section without a cursor. `nil` means the user is
///   scrolled above the first heading.
@MainActor
final class TOCBridge: NSObject, WKScriptMessageHandler {
  static let messageName = "toc"

  /// Pixels from the top of the viewport that mark a heading as
  /// "passed." 100px is a touch below the typical title-bar /
  /// toolbar inset and matches what GitBook / MDN use.
  private static let activeThresholdPx = 100

  /// Walk `<h1>…<h6>` once per load, slugify text into a unique id
  /// for any heading without one, post the flat list back, and then
  /// install a rAF-throttled scroll listener that posts the active
  /// heading id whenever it changes.
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
      var headingEls = [];
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
        headingEls.push(node);
      }
      window.webkit.messageHandlers.\(messageName).postMessage(
        { items: items });

      var threshold = \(activeThresholdPx);
      var lastActive = undefined;
      var ticking = false;
      function recomputeActive() {
        ticking = false;
        var newActive = null;
        for (var j = 0; j < headingEls.length; j++) {
          var top = headingEls[j].getBoundingClientRect().top;
          if (top <= threshold) {
            newActive = headingEls[j].id;
          } else {
            break;
          }
        }
        if (newActive !== lastActive) {
          lastActive = newActive;
          window.webkit.messageHandlers.\(messageName).postMessage(
            { activeId: newActive });
        }
      }
      function onScroll() {
        if (!ticking) {
          ticking = true;
          requestAnimationFrame(recomputeActive);
        }
      }
      window.addEventListener('scroll', onScroll, { passive: true });
      window.addEventListener('resize', onScroll, { passive: true });
      recomputeActive();
    })();
    """

  /// Set by the owning DocumentModel; receives the freshly-extracted
  /// heading list every time the page loads.
  var onHeadings: (([TOCEntry]) -> Void)?

  /// Set by the owning DocumentModel; receives the active heading id
  /// (or `nil` when the user is above all headings) on every change.
  var onActiveHeading: ((String?) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "TOCBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any] else {
      logMalformedMessage(message.body)
      return
    }
    if let items = body["items"] as? [[String: Any]] {
      let headings: [TOCEntry] = items.compactMap { entry in
        guard let id = entry["id"] as? String,
              let text = entry["text"] as? String,
              let level = entry["level"] as? Int
        else { return nil }
        return TOCEntry(id: id, level: level, text: text)
      }
      onHeadings?(headings)
      return
    }
    if body.keys.contains("activeId") {
      let id = body["activeId"] as? String
      onActiveHeading?(id)
      return
    }
    logMalformedMessage(message.body)
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed toc message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
