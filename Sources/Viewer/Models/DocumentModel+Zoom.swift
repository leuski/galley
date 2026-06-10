//
//  DocumentModel+Zoom.swift
//  Galley
//
//  Created by Anton Leuski on 5/9/26.
//

import WebKit
import GalleyCoreKit

extension DocumentModel {
  func zoomIn() {
    let next = Self.zoomStops.first { $0 > pageZoom + 0.001 }
    ?? Self.maxZoom
    setZoom(next)
  }

  func zoomOut() {
    let prev = Self.zoomStops.last { $0 < pageZoom - 0.001 }
    ?? Self.minZoom
    setZoom(prev)
  }

  func resetZoom() {
    setZoom(1.0)
  }

  /// Set zoom directly. Pinned to `[minZoom, maxZoom]`. Updates the
  /// live page via JS — no re-render needed.
  func setZoom(_ factor: Double) {
    let clamped = min(max(factor, Self.minZoom), Self.maxZoom)
    guard abs(clamped - pageZoom) > 0.001 else { return }
    pageZoom = clamped
    Task { await applyZoomToPage() }
  }

  /// Push the current `pageZoom` to the live document. Idempotent —
  /// updates the dedicated `<style>` element if present, otherwise
  /// inserts it.
  private struct ApplyZoomToPage: JavaScriptCallable<Void> {
    let pageZoom: Double
    var body: String {
      """
      (function(){
        var s = document.getElementById('md-eye-zoom');
        if (!s) {
          s = document.createElement('style');
          s.id = 'md-eye-zoom';
          document.head.appendChild(s);
        }
        s.textContent = \("html{zoom:\(pageZoom);}".jsStringLiteral);
      })();
      """
    }
  }

  private func applyZoomToPage() async {
    try? await page.callJavaScript(ApplyZoomToPage(pageZoom: pageZoom))
  }

  /// Embed the current zoom as a `<style>` element in the rendered
  /// HTML so the page comes up at the right size on the very first
  /// frame — applying via JS after load would briefly flash at 100%.
  func injectZoomStyle(into html: String) -> String {
    let style = "<style id=\"md-eye-zoom\">html{zoom:\(pageZoom);}</style>"
    if let range = html.range(
      of: "</head>", options: .caseInsensitive)
    {
      return html.replacingCharacters(in: range, with: style + "</head>")
    }
    return style + html
  }
}
