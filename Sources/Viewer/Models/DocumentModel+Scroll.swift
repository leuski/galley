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
import GalleyCoreKit

extension DocumentModel {

  enum Scroll: Codable, Hashable, Sendable {
    case line(Int)
    case location(Double)
  }

  /// Where the next render should land. Threaded as an argument from
  /// each bind entry point down to `renderCurrent` — replaces the
  /// former one-shot `pendingScroll` field.
  enum ScrollIntent: Sendable {
    /// Apply this exact target once: a `@SceneStorage` resting
    /// position (restore) or a `galley://…?line=N` source-line jump.
    case explicit(Scroll)
    /// Keep the reader's current position — file-watcher reload and
    /// `reload()`.
    case preserve
    /// Land at the top — fresh navigation, Back/Forward, rename.
    case top
  }

  /// Scroll the rendered preview to the heading identified by `id`.
  /// The TOC sidebar's row taps call this; the id is whatever the
  /// `TOCBridge` user script reported back — either the renderer-
  /// supplied anchor or our slugified fallback.
  /// `scrollIntoView({ behavior: 'smooth' })` returns synchronously and
  /// only *starts* an animation that runs for several hundred ms after.
  /// We need the call to stay pending until that animation settles, so
  /// `scrollToHeading`'s `isScrollingTOC` flag covers the whole scroll
  /// and the tocController's scroll-driven `activeId` posts are all
  /// suppressed. Resolve once `window.scrollY` has held steady for a few
  /// frames — works for smooth, instant, and no-op scrolls alike, with
  /// no dependency on `scrollend` event support.
  private struct ScrollToHeading: JavaScriptCallable<Void> {
    let id: TOCEntry.ID

    var body: String {
      """
      return await new Promise(function(resolve) {
        var node = document.getElementById(\(id.rawValue.jsStringLiteral));
        if (!node) { resolve(); return; }
        node.scrollIntoView({ block: 'start', behavior: 'smooth' });
        var lastY = null, stableFrames = 0;
        function tick() {
          var y = window.scrollY;
          if (y === lastY) {
            stableFrames += 1;
            if (stableFrames >= 3) { resolve(); return; }
          } else {
            stableFrames = 0;
            lastY = y;
          }
          requestAnimationFrame(tick);
        }
        requestAnimationFrame(tick);
      });
      """
    }
  }

  /// Scroll the rendered preview to `id`, cancelling any scroll already
  /// in flight so a later tap preempts the current smooth scroll. The
  /// JS promise resolves only when the scroll settles, so `isScrollingTOC`
  /// stays `true` across the whole animation (and across a handoff to a
  /// newer tap) — suppressing the tocController's scroll-driven `activeId`
  /// posts the entire time. Only the latest, un-cancelled task clears the
  /// flag; main-actor serialization makes the cancel/clear race-free.
  func scrollToHeading(id: TOCEntry.ID) {
    tocScrollTask?.cancel()
    tocScrollTask = Task { [weak self] in
      guard let self else { return }
      try? await page.callJavaScript(ScrollToHeading(id: id))
      guard !Task.isCancelled else { return }
      tocScrollTask = nil
    }
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
