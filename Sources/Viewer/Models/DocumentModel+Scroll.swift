//
//  DocumentModel+Scroll.swift
//  Galley
//
//  Created by Anton Leuski on 5/8/26.
//

import Foundation
import OSLog
import WebKit
import KosmosAppKit

extension DocumentModel {

  enum Scroll: Codable, Hashable, Sendable {
    case line(Int)
    case location(Double)
  }

  /// Scroll the rendered preview to the heading identified by `id`.
  /// The TOC sidebar's row taps call this; the id is whatever the
  /// `TOCBridge` user script reported back — either the renderer-
  /// supplied anchor or our slugified fallback.
  private struct ScrollToHeading: JavaScriptCallable<Void> {
    let id: String

    var body: String {
      """
      (function() {
        var node = document.getElementById(\(id.jsStringLiteral));
        if (node) {
          node.scrollIntoView({ block: 'start', behavior: 'smooth' });
        }
      })();
      """
    }
  }

  func scrollToHeading(id: String) async {
    try? await page.callJavaScript(ScrollToHeading(id: id))
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
  /// Public so DocumentSceneContent can fire a scroll-only update when a
  /// `galley://` open targets a URL already bound to a window —
  /// we don't want to reset history just to re-jump the cursor.

  private struct ScrollToSourceLine: JavaScriptCallable<Void> {
    let line: Int

    var body: String {
      """
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
    }
  }

  private func scrollToSourceLine(_ line: Int) async {
    try? await page.callJavaScript(ScrollToSourceLine(line: line))
  }

  private struct CurrentScrollY: JavaScriptCallable<Double> {
    var body: String {
      "return window.scrollY;"
    }
  }

  func currentScrollY() async -> Double? {
    do {
      return try await page.callJavaScript(CurrentScrollY())
    } catch {
      logger.debug("""
        currentScrollY JS failed: \
        \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }

  private struct RestoreScrollY: JavaScriptCallable<Void> {
    let yPos: Double
    var body: String {
      "window.scrollTo(0, \(yPos));"
    }
  }

  private func restoreScrollY(_ yPos: Double) async {
    try? await page.callJavaScript(RestoreScrollY(yPos: yPos))
  }

  func scroll(to scroll: Scroll) async {
    switch scroll {
    case .line(let line):
      await scrollToSourceLine(line)
    case .location(let yPos):
      await restoreScrollY(max(0, yPos))
    }
  }
}
