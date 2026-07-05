//
//  DocumentModel+PDFShared.swift
//  Galley
//
//  Cross-platform PDF/print plumbing shared by the macOS print path
//  (`DocumentModel+Print`) and the visionOS export path
//  (`DocumentModel+Export`). Everything here uses only WebKit +
//  CoreTransferable + Foundation, which exist on both platforms — the
//  framework-specific PDF recipes (NSPrintOperation vs
//  UIPrintPageRenderer) live in the per-platform files.
//

import CoreTransferable
import Foundation
import GalleyCoreKit
import UniformTypeIdentifiers
import WebKit

extension DocumentModel {
  /// `Transferable` representation of this document's exportable PDF.
  /// The render closure runs only when the user actually shares /
  /// exports — until then no PDF is generated.
  func pdfExport(appModel: AppModel) -> PDFExport {
    PDFExport(
      suggestedName: documentURL.deletingPathExtension().lastPathComponent
    ) { [weak self] in
      guard let self else { throw CocoaError(.featureUnsupported) }
      return try await self.exportPDF(appModel: appModel)
    }
  }

  /// Compose the preview HTML the same way `renderCurrent` does —
  /// renderer → template → placeholder substitution — minus the
  /// live-zoom style. PDF renders at 100% regardless of on-screen
  /// zoom.
  func buildComposedPreview(
    template: Template, appModel: AppModel
  ) async throws -> ComposedPreview {
    let url = documentURL
    let renderer = resolvedRenderer(appModel: appModel)
    let source = try String(contentsOf: url, encoding: .utf8)
    let body = try await renderer.render(source, baseURL: url)
    return try template.composeHTML(
      documentContent: body,
      documentURL: url,
      origin: PreviewSchemeHandler.originURL)
  }

  /// Spin up a fresh `WKWebView` configured with the shared scheme
  /// handler, load `composed.html` under `composed.baseURL`, and
  /// resume once the load settles. Sized to `size` (the printable /
  /// paper measure) so the platform print pipeline paginates at the
  /// right measure without a mid-render rescale.
  func loadOffscreenWebView(
    composed: ComposedPreview,
    template: Template,
    size: CGSize
  ) async -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let handler = ClassicPreviewSchemeHandler(
      templateProvider: { template })
    configuration.setURLSchemeHandler(
      handler, forURLScheme: PreviewSchemeHandler.scheme.rawValue)

    let webView = WKWebView(
      frame: CGRect(origin: .zero, size: size),
      configuration: configuration)

    let bridge = OffscreenLoadBridge()
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
/// completion into a continuation, so the print/export operation only
/// runs after layout has settled.
@MainActor
final class OffscreenLoadBridge: NSObject, WKNavigationDelegate {
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
/// closure. SwiftUI's `ShareLink(item:)` / `.fileExporter(item:)`
/// invokes the closure only when the user actually shares / confirms a
/// destination, then moves the returned temp file via
/// `SentTransferredFile(_:allowAccessingOriginalFile: true)` — so
/// cancellation does no work and there's no `Data` round-trip.
/// `suggestedName` becomes the filename the receiving app sees (no
/// extension; `FileRepresentation` appends `.pdf`).
///
/// The closure is `@MainActor` because `DocumentModel` is main-actor-
/// isolated; main-actor-isolated function values are `Sendable`, so
/// `PDFExport` satisfies `Transferable`'s `Sendable` requirement
/// without further annotation.
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
