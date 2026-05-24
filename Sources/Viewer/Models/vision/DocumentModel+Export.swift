//
//  DocumentModel+Export.swift
//  Galley (visionOS)
//

#if !os(macOS)
import CoreTransferable
import Foundation
import GalleyCoreKit
import UIKit
import UniformTypeIdentifiers
import WebKit
import ALFoundation

extension DocumentModel {
  // MARK: - PDF export

  /// `Transferable` representation of this document's exportable
  /// PDF. The render closure runs only when the user actually picks
  /// the PDF row in the Share menu — until then no PDF is generated.
  var pdfExport: PDFExport {
    PDFExport(
      suggestedName: documentURL.deletingPathExtension().lastPathComponent
    ) { [weak self] in
      guard let self else { throw CocoaError(.featureUnsupported) }
      return try await self.exportPDF()
    }
  }

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
  func exportPDF() async throws -> URL {
    let template = resolvedTemplate()
    let composed = try await buildComposedPreview(template: template)

    // US Letter @ 72 dpi with half-inch margins. Matches the macOS
    // print pipeline's default `NSPrintInfo` paper / margins so the
    // two platforms produce visually similar output for the same
    // document.
    let paperRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    let printableRect = paperRect.insetBy(dx: 36, dy: 36)

    let webView = await loadOffscreenWebView(
      composed: composed,
      template: template,
      contentWidth: printableRect.width)

    // The print formatter respects the web view's bounds.width when
    // laying out content. We sized the web view to `printableRect`
    // width above so the formatter paginates at the right horizontal
    // measure without needing a separate scale factor.
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

  /// Compose the preview HTML the same way `renderCurrent` does —
  /// renderer → template → placeholder substitution — minus the
  /// live-zoom style. PDF renders at 100% regardless of on-screen
  /// zoom.
  private func buildComposedPreview(
    template: Template
  ) async throws -> ComposedPreview {
    let url = documentURL
    let renderer = resolvedRenderer()
    let source = try String(contentsOf: url, encoding: .utf8)
    let body = try await renderer.render(source, baseURL: url)
    return try template.composeHTML(
      documentContent: body,
      documentURL: url,
      origin: PreviewSchemeHandler.originURL)
  }

  /// Spin up a fresh `WKWebView` configured with the shared scheme
  /// handler, load `composed.html` under `composed.baseURL`, and
  /// resume once `didFinish` fires plus one extra runloop turn so
  /// auto layout has had a chance to settle before the print
  /// formatter inspects the view.
  ///
  /// Width is fixed to `contentWidth` (the printable rect width).
  /// `UIPrintPageRenderer` uses `viewPrintFormatter()` and the print
  /// formatter scales content to fit the web view's bounds.width,
  /// so matching the printable measure up front avoids a mid-render
  /// rescale that can introduce blurry text and clipped wide blocks.
  /// Height is generous so all content renders before the formatter
  /// queries `numberOfPages`.
  private func loadOffscreenWebView(
    composed: ComposedPreview,
    template: Template,
    contentWidth: CGFloat
  ) async -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let handler = ClassicPreviewSchemeHandler(
      templateProvider: { template })
    configuration.setURLSchemeHandler(
      handler, forURLScheme: PreviewSchemeHandler.scheme.rawValue)

    let webView = WKWebView(
      frame: CGRect(x: 0, y: 0, width: contentWidth, height: 1),
      configuration: configuration)

    let bridge = ExportLoadBridge()
    webView.navigationDelegate = bridge

    return await withCheckedContinuation { continuation in
      bridge.completion = { [weak webView] in
        continuation.resume(returning: webView ?? WKWebView())
      }
      webView.loadHTMLString(composed.html, baseURL: composed.baseURL)
    }
  }
}

/// Tiny `WKNavigationDelegate` adapter that bridges WebKit's load
/// completion into a continuation. Sibling of macOS's
/// `PrintLoadBridge` — kept separate so neither file leaks AppKit /
/// UIKit imports across `#if` walls.
@MainActor
private final class ExportLoadBridge: NSObject, WKNavigationDelegate {
  var completion: (() -> Void)?
  private var didFire = false

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    fire()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    fire()
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    fire()
  }

  private func fire() {
    guard !didFire else { return }
    didFire = true
    completion?()
    completion = nil
  }
}

/// `Transferable` wrapper around a lazy "render to a temp PDF file"
/// closure. `ShareLink(item:)` invokes the closure only when the
/// user actually shares — cancelling or never opening the PDF row
/// does no work. `suggestedName` becomes the filename the receiving
/// app sees (no extension; `FileRepresentation` appends `.pdf`).
struct PDFExport: Transferable {
  let suggestedName: String
  let render: @MainActor () async throws -> URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .pdf) { item in
      let url = try await item.render()
      return SentTransferredFile(
        url, allowAccessingOriginalFile: true)
    }
    .suggestedFileName { $0.suggestedName }
  }
}

#endif
