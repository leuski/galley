//
//  DocumentModel+Print.swift
//  Galley
//
//  Created by Anton Leuski on 5/2/26.
//

#if os(macOS)
import AppKit
import GalleyCoreKit
import OSLog
import Synchronization
import WebKit

extension DocumentModel {
  // MARK: - Print / Export

  /// Render the current document as PDF into a freshly-allocated temp
  /// file and return its URL. Used by the `.fileExporter`-driven
  /// Export as PDF flow: SwiftUI takes ownership of the temp via
  /// `SentTransferredFile(_:allowAccessingOriginalFile: true)` and
  /// moves the bytes into the user's chosen destination.
  ///
  /// The print operation's modal is pinned to a fresh offscreen host
  /// (not the document window) because SwiftUI's `.fileExporter`
  /// sheet is still up while this closure runs — stacking another
  /// modal on the same window would clash. Both `showsPrintPanel`
  /// and `showsProgressPanel` are off, so the modal is invisible —
  /// just a run-loop attachment point for `runModal(for:)`.
  func exportPDF() async throws -> URL {
    let destination = URL.temporaryDirectory / "\(UUID().uuidString).pdf"
    let host = Self.makeOffscreenHostWindow()
    let didSucceed = try await runPrintOperation(
      jobTitle: documentURL.lastPathComponent,
      on: host
    ) { operation, _ in
      let info = operation.printInfo
      info.jobDisposition = .save
      info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL]
      = destination as NSURL
      operation.showsPrintPanel = false
      operation.showsProgressPanel = false
    }
    // The caller hands this URL to SwiftUI's exporter, which opens it
    // at once — so never return a path with nothing behind it.
    guard didSucceed, destination.itemExists else {
      throw CocoaError(
        .fileNoSuchFile,
        userInfo: [NSFilePathErrorKey: destination.path])
    }
    return destination
  }

  /// Show the system Print panel for the current document. Renders
  /// the current HTML into a fresh offscreen `WKWebView` (which
  /// _does_ expose `printOperation(with:)`, unlike SwiftUI's
  /// `WebPage`) and runs the panel as a sheet on `window`. The
  /// panel's "PDF ▾" submenu produces a paginated PDF for free.
  func runPrintPanel(on window: NSWindow?) async {
    do {
      _ = try await runPrintOperation(
        jobTitle: documentURL.lastPathComponent,
        on: window
      ) { operation, _ in
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
      }
    } catch {
      report(failure: error, context: "print", lifetime: .ephemeral)
    }
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
  /// 3. `runModal(for:…)` returns *before* the job has finished — the
  ///    spool is written on a separate thread
  ///    (`NSPrintOperation.canSpawnSeparateThread`) and the file lands
  ///    on disk a moment later. The only completion signal is the
  ///    `didRun:` selector, so this suspends on it and returns the
  ///    operation's success flag; returning on `runModal` alone handed
  ///    Export-as-PDF a destination that did not exist yet.
  @discardableResult
  private func runPrintOperation(
    jobTitle: String,
    on window: NSWindow?,
    configure: (NSPrintOperation, NSPrintInfo) -> Void
  ) async throws -> Bool {
    let template = resolvedTemplate()
    let composed = try await buildComposedPreview(
      template: template)

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
      size: baseInfo.paperSize)

    let operation = webView.printOperation(with: baseInfo)
    operation.view?.frame = NSRect(
      origin: .zero, size: baseInfo.paperSize)
    operation.jobTitle = jobTitle
    configure(operation, baseInfo)

    let host = window
    ?? NSApp.keyWindow
    ?? Self.makeOffscreenHostWindow()
    let completion = PrintCompletionBridge()
    let didSucceed = await withCheckedContinuation { continuation in
      completion.arm(continuation)
      operation.runModal(
        for: host,
        delegate: completion,
        didRun: #selector(
          PrintCompletionBridge.printOperationDidRun(_:success:contextInfo:)),
        contextInfo: nil)
    }

    // Hold the web view and the delegate until the job has finished —
    // `printOperation` captures its view, but the implicit retain
    // cycle through configuration → handler can otherwise drop early
    // on some builds, and `runModal` keeps only an unretained delegate.
    withExtendedLifetime((webView, completion)) {}
    return didSucceed
  }

  /// Bridges `NSPrintOperation`'s `didRun:` selector callback into a
  /// continuation. AppKit delivers the callback on the operation's
  /// own spool thread (`NSConcretePrintOperation
  /// _finishModalOperation` off an `NSThread`), so this type is
  /// deliberately not main-actor-isolated — resuming a continuation is
  /// legal from any thread, and the lock makes the one-shot handoff
  /// race-free. Fires once; a second callback is ignored.
  private final class PrintCompletionBridge: NSObject, @unchecked Sendable {
    private let state = Mutex<CheckedContinuation<Bool, Never>?>(nil)

    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
      state.withLock { $0 = continuation }
    }

    @objc func printOperationDidRun(
      _ printOperation: NSPrintOperation,
      success: Bool,
      contextInfo: UnsafeMutableRawPointer?
    ) {
      let continuation = state.withLock { slot in
        defer { slot = nil }
        return slot
      }
      continuation?.resume(returning: success)
    }
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

#endif
