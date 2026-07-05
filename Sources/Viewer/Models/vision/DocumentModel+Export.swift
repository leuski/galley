//
//  DocumentModel+Export.swift
//  Galley (visionOS)
//

#if !os(macOS)
import Foundation
import GalleyCoreKit
import UIKit
import WebKit

extension DocumentModel {
  // MARK: - PDF export

  /// Build a fresh offscreen `WKWebView`, load the current rendered
  /// HTML into it, await layout, then paginate the rendered content
  /// onto US Letter pages via `UIPrintPageRenderer`. Returns the
  /// temp PDF file URL.
  ///
  /// `WKWebView.pdf(configuration:)` is *not* a pagination tool — it
  /// returns either one tall page (rect=nil) or a single page of the
  /// rect you pass. To get a multi-page PDF on iOS-family platforms
  /// the canonical recipe is `UIPrintPageRenderer` driven by the
  /// web view's `viewPrintFormatter()` plus a `UIGraphicsPDFRenderer`
  /// context. Both APIs are available on visionOS (only `tvos` /
  /// `watchos` are marked unavailable in the SDK headers).
  ///
  /// The macOS sibling routes through `NSPrintOperation` for the
  /// same reason — and additionally honors `@page` CSS margins,
  /// which `UIPrintPageRenderer` does not. That's a quality
  /// difference but not a correctness one for our use case.
  func exportPDF(appModel: AppModel) async throws -> URL {
    let template = resolvedTemplate(appModel: appModel)
    let composed = try await buildComposedPreview(
      template: template, appModel: appModel)

    // US Letter @ 72 dpi with half-inch margins. Matches the macOS
    // print pipeline's default `NSPrintInfo` paper / margins so the
    // two platforms produce visually similar output for the same
    // document.
    let paperRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    let printableRect = paperRect.insetBy(dx: 36, dy: 36)

    // The print formatter respects the web view's bounds.width when
    // laying out content. Sizing the web view to the printable width
    // up front lets the formatter paginate at the right horizontal
    // measure without a separate scale factor. Height is generous so
    // all content renders before the formatter queries
    // `numberOfPages`.
    let webView = await loadOffscreenWebView(
      composed: composed,
      template: template,
      size: CGSize(width: printableRect.width, height: 1))

    let formatter = webView.viewPrintFormatter()
    let pageRenderer = UIPrintPageRenderer()
    pageRenderer.addPrintFormatter(formatter, startingAtPageAt: 0)
    pageRenderer.setValue(
      NSValue(cgRect: paperRect), forKey: "paperRect")
    pageRenderer.setValue(
      NSValue(cgRect: printableRect), forKey: "printableRect")

    let pdfRenderer = UIGraphicsPDFRenderer(bounds: paperRect)
    let data = pdfRenderer.pdfData { context in
      // Touch `numberOfPages` after the formatter and paper rects
      // are wired — it triggers the formatter's pagination pass.
      let pageCount = pageRenderer.numberOfPages
      for index in 0..<pageCount {
        context.beginPage()
        pageRenderer.drawPage(at: index, in: paperRect)
      }
    }

    // Write into a fresh UUID-named subdirectory so the visible
    // filename can be the document's own name without colliding when
    // the user exports two same-named files. The share sheet's Save
    // to Files / AirDrop destinations use the file's basename — the
    // `FileRepresentation.suggestedFileName` hint isn't always
    // honored once `SentTransferredFile(_:allowAccessingOriginalFile:
    // true)` lets the recipient touch the file directly.
    let dir = URL.temporaryDirectory / UUID().uuidString
    try dir.createDirectory()
    let destination = dir / "\(documentURL.fileName).pdf"
    try data.write(to: destination, options: .atomic)
    return destination
  }
}

#endif
