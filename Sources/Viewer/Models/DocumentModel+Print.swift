//
//  DocumentModel+Print.swift
//  Galley
//
//  Created by Anton Leuski on 5/2/26.
//

import AppKit
import WebKit
import GalleyCoreKit
import os

extension DocumentModel {
  // MARK: - Print / Export

  /// Render the current document as PDF and write the bytes to
  /// `destination`. Drives the same `WKWebView.printOperation`
  /// pipeline as Print, but pre-mutates the print info to save to a
  /// file URL with no panel — that's how AppKit's print pipeline
  /// produces a properly paginated PDF. The screenshot-style
  /// `WebPage.exported(as: .pdf())` doesn't paginate at all and is
  /// not suitable for this path.
  func exportPDF(to destination: URL, on window: NSWindow?) async throws {
    try await runPrintOperation(
      jobTitle: documentURL.lastPathComponent,
      on: window
    ) { operation, _ in
      let info = operation.printInfo
      info.jobDisposition = .save
      info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL]
      = destination as NSURL
      operation.showsPrintPanel = false
      operation.showsProgressPanel = true
    }
  }

  /// Show the system Print panel for the current document. Renders
  /// the current HTML into a fresh offscreen `WKWebView` (which
  /// _does_ expose `printOperation(with:)`, unlike SwiftUI's
  /// `WebPage`) and runs the panel as a sheet on `window`. The
  /// panel's "PDF ▾" submenu produces a paginated PDF for free.
  func runPrintPanel(on window: NSWindow?) async {
    do {
      try await runPrintOperation(
        jobTitle: documentURL.lastPathComponent,
        on: window
      ) { operation, _ in
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
      }
      lastError = nil
    } catch {
      logPrintFailed(error)
      lastError = error.localizedDescription
    }
  }

  private func logPrintFailed(_ error: any Error) {
    logger.error("""
      print failed: \(error.localizedDescription, privacy: .public)
      """)
  }

  /// Show the system Page Setup sheet on `window` (app-modal fallback
  /// when no window is supplied). Edits `NSPrintInfo.shared` in place
  /// so the next `runPrintPanel` picks up the new paper size, margins,
  /// orientation, etc.
  func runPageSetup(on window: NSWindow?) {
    let layout = NSPageLayout()
    if let window {
      layout.beginSheet(
        using: NSPrintInfo.shared,
        on: window,
        completionHandler: nil)
    } else {
      _ = layout.runModal(with: NSPrintInfo.shared)
    }
  }

  /// Spin up an offscreen `WKWebView`, load the current rendered
  /// HTML into it, and run an `NSPrintOperation` against it. Both
  /// Print and Export funnel through here so the pagination, paper
  /// size, `@page` margins, and `@media print` styles all behave
  /// identically.
  ///
  /// Two non-obvious bits of macOS print plumbing live here, both
  /// confirmed by current Apple-forums threads:
  ///
  /// 1. `operation.view?.frame` _must_ be set to the paper size — an
  ///    unset frame either crashes or produces blank output.
  /// 2. We invoke `runModal(for:delegate:didRun:contextInfo:)`, not
  ///    `runOperation()`. The latter produces blank pages (and blank
  ///    files when saving) because WebKit's print pipeline only
  ///    runs when dispatched onto the run loop the way the modal
  ///    variant does. Despite the name, we're not displaying a
  ///    sheet for the save path — the print panel is suppressed by
  ///    the export path's configurator.
  private func runPrintOperation(
    jobTitle: String,
    on window: NSWindow?,
    configure: (NSPrintOperation, NSPrintInfo) -> Void
  ) async throws {
    let template = resolvedTemplate()
    let composed = try await buildComposedPreview(template: template)

    // Fresh print info per operation — `runModal` tucks per-op
    // state into the dict (jobDisposition, savingURL) and we don't
    // want to scribble those onto the shared instance.
    guard let baseInfo
            = NSPrintInfo.shared.copy() as? NSPrintInfo
    else {
      throw CocoaError(.featureUnsupported)
    }
    // Pagination must be automatic — without these flags the
    // operation prints the entire document onto a single tall page
    // (the same failure mode `WebPage.exported(as: .pdf())` has).
    baseInfo.horizontalPagination = .automatic
    baseInfo.verticalPagination = .automatic
    baseInfo.isVerticallyCentered = false
    baseInfo.isHorizontallyCentered = false

    let webView = await loadOffscreenWebView(
      composed: composed,
      template: template,
      paperSize: baseInfo.paperSize)

    let operation = webView.printOperation(with: baseInfo)
    operation.view?.frame = NSRect(
      origin: .zero, size: baseInfo.paperSize)
    operation.jobTitle = jobTitle
    configure(operation, baseInfo)

    let host = window
    ?? NSApp.keyWindow
    ?? Self.makeOffscreenHostWindow()
    operation.runModal(
      for: host,
      delegate: nil as Any?,
      didRun: nil as Selector?,
      contextInfo: nil)

    // Hold the web view until runModal returns — `printOperation`
    // captures its view, but the implicit retain cycle through
    // configuration → handler can otherwise drop early on some
    // builds. Belt-and-braces.
    withExtendedLifetime(webView) {}
  }

  /// Build a fresh `WKWebView` configured with our scheme handler,
  /// load `html` into it, and await `didFinish` before returning.
  /// Sized to the print paper so layout matches what the print
  /// pipeline will paginate.
  private func loadOffscreenWebView(
    composed: ComposedPreview,
    template: Template,
    paperSize: NSSize
  ) async -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let handler = ClassicPreviewSchemeHandler(
      templateProvider: { template })
    configuration.setURLSchemeHandler(
      handler, forURLScheme: PreviewSchemeHandler.scheme.rawValue)

    let webView = WKWebView(
      frame: NSRect(origin: .zero, size: paperSize),
      configuration: configuration)

    let bridge = PrintLoadBridge()
    webView.navigationDelegate = bridge

    return await withCheckedContinuation { continuation in
      bridge.completion = { [weak webView] in
        guard let webView else {
          continuation.resume(returning: WKWebView())
          return
        }
        continuation.resume(returning: webView)
      }
      webView.loadHTMLString(composed.html, baseURL: composed.baseURL)
    }
  }

  /// Build the preview the print/export web view loads — same
  /// `composeHTML` pipeline `renderCurrent` uses, minus the live-zoom
  /// style. Print renders at 100 % regardless of the on-screen zoom
  /// factor.
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

  /// Last-resort host window for `runModal(for:)` when no other
  /// window is available. Stays offscreen — the user never sees it,
  /// it just gives the print pipeline something to attach to.
  private static func makeOffscreenHostWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
      styleMask: [],
      backing: .buffered,
      defer: true)
  }

}

/// Tiny `WKNavigationDelegate` adapter that bridges WebKit's load
/// completion into a continuation. Used by the offscreen print web
/// view so the print operation only runs after layout has settled.
@MainActor
private final class PrintLoadBridge: NSObject, WKNavigationDelegate {
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
