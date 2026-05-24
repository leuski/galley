//
//  DocumentModel+Scroll.swift
//  Galley
//
//  Created by Anton Leuski on 5/8/26.
//

import Foundation
import OSLog
import WebKit

extension DocumentModel {

  /// Scroll the rendered preview to the heading identified by `id`.
  /// The TOC sidebar's row taps call this; the id is whatever the
  /// `TOCBridge` user script reported back — either the renderer-
  /// supplied anchor or our slugified fallback.
  func scrollToHeading(id: String) async {
    let escaped = jsStringLiteral(id)
    let script = """
      (function() {
        var node = document.getElementById(\(escaped));
        if (node) {
          node.scrollIntoView({ block: 'start', behavior: 'smooth' });
        }
      })();
      """
    _ = try? await page.callJavaScript(script)
  }

  /// Find the rendered block whose source line is closest to (but not
  /// past) `line` and scroll it into view. Reads any of the three
  /// source-position attribute formats we know about:
  ///
  /// - `data-source-line="42"` — `SwiftMarkdownRenderer`
  /// - `data-pos="…42:1-42:17"` — pandoc with `+sourcepos`
  /// - `data-sourcepos="42:1-42:17"` — cmark-gfm with `--sourcepos`
  ///
  /// No-ops cleanly when the active renderer doesn't emit positions
  /// (multimarkdown, discount, Markdown.pl) — the user just lands at
  /// the top of the document.
  ///
  /// Public so ContentView can fire a scroll-only update when a
  /// `galley://` open targets a URL already bound to a window —
  /// we don't want to reset history just to re-jump the cursor.
  func scrollToSourceLine(_ line: Int) async {
    let script = """
      (function() {
        var nodes = document.querySelectorAll(
          '[data-source-line], [data-pos], [data-sourcepos]');
        var best = null;
        var bestLine = -1;
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          var n = NaN;
          if (node.dataset.sourceLine) {
            n = parseInt(node.dataset.sourceLine, 10);
          } else {
            var raw = node.dataset.pos || node.dataset.sourcepos || '';
            var m = raw.match(/(\\d+):\\d+/);
            if (m) n = parseInt(m[1], 10);
          }
          if (Number.isNaN(n)) continue;
          if (n <= \(line) && n > bestLine) {
            best = node;
            bestLine = n;
          }
        }
        if (best) {
          best.scrollIntoView({ block: 'center', behavior: 'instant' });
        }
      })();
      """
    _ = try? await page.callJavaScript(script)
  }

  func currentScrollY() async -> Double? {
    do {
      let value = try await page.callJavaScript("return window.scrollY;")
      if let number = value as? Double { return number }
      if let number = value as? NSNumber { return number.doubleValue }
      return nil
    } catch {
      logger.debug("""
        currentScrollY JS failed: \
        \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }

  func restoreScrollY(_ yPos: Double) async {
    _ = try? await page.callJavaScript("window.scrollTo(0, \(yPos));")
  }

}

/// Escape a Swift string into a JavaScript double-quoted string
/// literal. Only used for a CSS rule we control, but kept strict so
/// future zoom-related callers can pass arbitrary text safely.
func jsStringLiteral(_ value: String) -> String {
  var out = "\""
  for scalar in value.unicodeScalars {
    switch scalar {
    case "\\": out += "\\\\"
    case "\"": out += "\\\""
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case "\u{2028}": out += "\\u2028"
    case "\u{2029}": out += "\\u2029"
    default:
      if scalar.value < 0x20 {
        out += String(format: "\\u%04x", scalar.value)
      } else {
        out += String(scalar)
      }
    }
  }
  out += "\""
  return out
}
