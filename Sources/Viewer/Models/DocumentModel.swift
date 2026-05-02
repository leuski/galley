import AppKit
import Foundation
import GalleyCoreKit
import Observation
import os
import SwiftUI
import WebKit

/// Per-document state for the native viewer. Owns the WebPage, the
/// file watcher, and the editor bridge. Renderer and template come
/// from the shared `AppModel` so global selection changes
/// re-render every open window.
///
/// In-window navigation is browser-style: clicking a markdown link
/// rebinds this same model. A back/forward stack tracks the visited
/// URLs; toolbar buttons drive `goBack`, `goForward`, and `reload`.
@Observable
@MainActor
final class DocumentModel {
  let page: WebPage

  @ObservationIgnored private let watcher = DocumentWatcher()
  @ObservationIgnored private let bridge = EditorBridge()
  @ObservationIgnored private let linkBridge = LinkBridge()
  @ObservationIgnored private let scrollBridge = ScrollBridge()
  @ObservationIgnored private weak var appModel: AppModel?
  @ObservationIgnored private let templateBox: TemplateBox

  /// Per-window template / processor choices. Reference types so
  /// SwiftUI's Observation tracks `selected` for menus that bind to
  /// them. `nil` until `bindSettings(_:)` runs.
  var templates: SceneTemplateChoice?
  var processors: SceneProcessorChoice?

  private(set) var documentURL: URL?
  private(set) var lastError: String?

  /// Page zoom factor for the rendered preview. Applied via a CSS
  /// `zoom` rule injected into the document head; updated live via JS
  /// when the user changes it without re-rendering.
  private(set) var pageZoom: Double = 1.0

  /// Discrete zoom stops, matching what Safari and Preview offer so
  /// repeated ⌘+ presses land on familiar values.
  private static let zoomStops: [Double] = [
    0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0
  ]
  private static let minZoom: Double = 0.5
  private static let maxZoom: Double = 3.0

  var canZoomIn: Bool { pageZoom < Self.maxZoom - 0.001 }
  var canZoomOut: Bool { pageZoom > Self.minZoom + 0.001 }
  var canResetZoom: Bool { abs(pageZoom - 1.0) > 0.001 }

  /// Visited documents in chronological order; `currentIndex` points
  /// at the one currently rendered. Navigation actions move
  /// `currentIndex` and rebind without truncating the stack — so
  /// pressing Forward after Back works.
  private var history: [URL] = []
  private var currentIndex: Int = -1

  var canGoBack: Bool { currentIndex > 0 }
  var canGoForward: Bool {
    currentIndex >= 0 && currentIndex < history.count - 1 }

  /// Increments on every `bind(to:)` call. Watcher loops captured by
  /// older bind invocations check this and bail out when superseded.
  @ObservationIgnored private var bindGeneration: Int = 0

  /// One-shot source-line scroll target consumed by the next render.
  /// Set by `bind(to:scrollToLine:)` for `galley://...?line=N` opens
  /// dispatched from BBEdit's preview script; cleared after the JS
  /// scroll runs so subsequent file-watcher reloads don't re-jump.
  @ObservationIgnored private var pendingScrollLine: Int?

  /// One-shot pixel scroll target consumed by the next render. Set
  /// by `bind` / `restore` from the window's persisted
  /// `@SceneStorage` slot so a freshly-launched window comes back at
  /// the position it was left. Cleared after one apply so in-window
  /// navigation and file-watcher reloads aren't jerked back.
  @ObservationIgnored private var pendingScrollY: Double?

  /// Latest known scroll position, updated by `ScrollBridge` from a
  /// debounced JS listener. ContentView mirrors this to
  /// `@SceneStorage` so the next session can hydrate `pendingScrollY`.
  private(set) var currentScrollY: Double = 0

  private let logger = Logger(
    subsystem: bundleIdentifier, category: "DocumentModel")

  init() {
    var configuration = WebPage.Configuration()
    let controller = configuration.userContentController
    controller.add(bridge, name: EditorBridge.messageName)
    controller.add(linkBridge, name: LinkBridge.messageName)
    controller.add(scrollBridge, name: ScrollBridge.messageName)
    // One script handles both cmd-click → editor and plain click →
    // in-window nav, so we don't depend on capture-phase ordering
    // between two listeners — which appears to drop the editor
    // listener after the first navigation in macOS 26 WebPage.
    controller.addUserScript(WKUserScript(
      source: EditorBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Debounced scroll listener — feeds `currentScrollY` so
    // ContentView can persist the resting position via `@SceneStorage`.
    controller.addUserScript(WKUserScript(
      source: ScrollBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))

    // Custom URL scheme so template-bundled assets (CSS, fonts,
    // images) resolve from disk through the SwiftUI WebView. Reads
    // the active template at request time via `templateBox`, which
    // is populated by `bindSettings(_:)`.
    let box = TemplateBox()
    self.templateBox = box
    let handler = PreviewSchemeHandler(
      templateProvider: { box.template ?? .default })
    configuration.urlSchemeHandlers[PreviewSchemeHandler.scheme] = handler

    self.page = WebPage(configuration: configuration)

    // Browser-style navigation: clicking a markdown link in the
    // rendered preview pushes onto our history and rebinds this same
    // model rather than opening a new document window.
    linkBridge.onMarkdownLink = { [weak self] url in
      guard let self else { return }
      Task { await self.navigate(to: url) }
    }

    // Cmd-click in the preview: route through the model so we read
    // the current `EditorChoice` from appModel on every click.
    bridge.onEditorClick = { [weak self] line in
      guard let self else { return }
      Task { await self.openInEditor(line: line) }
    }

    // Latest debounced scroll position. `@ObservationIgnored` would
    // suppress the SwiftUI invalidation that lets ContentView mirror
    // this to `@SceneStorage`, so we leave it observed — the listener
    // fires at most every ~150 ms, well below per-frame cost.
    scrollBridge.onScroll = { [weak self] y in
      guard let self else { return }
      currentScrollY = y
    }
  }

  /// Open the current document in the user's chosen editor.
  /// `line` is non-nil for cmd-click on a `data-source-line` block.
  /// When nil (File > Open in Editor), we try to land the editor on
  /// the source line the user is currently reading by querying the
  /// topmost visible position-tagged block in the WebView; falls
  /// back to opening at the file with no line if the active renderer
  /// emits no source positions.
  func openInEditor(line: Int? = nil) async {
    guard let url = documentURL else {
      logger.warning("openInEditor ignored: no document URL bound")
      return
    }
    let resolvedLine: Int?
    if let line {
      resolvedLine = line
    } else {
      resolvedLine = await topmostVisibleSourceLine()
    }
    let value = appModel?.editors.selected ?? .default
    await openFileInEditor(
      value, fileURL: url, line: resolvedLine, logger: logger)
  }

  /// Find the smallest source line of any block currently in (or
  /// just above) the viewport. Reads the same three attribute
  /// flavors `EditorBridge` understands. Returns nil if the active
  /// renderer doesn't emit source positions, or if no positioned
  /// block is visible (very short docs, mostly).
  private func topmostVisibleSourceLine() async -> Int? {
    // `callJavaScript` wraps the source in an async function and
    // captures a top-level `return`. An IIFE here would just
    // discard its value — the bug that made every "Open in
    // Editor" land at the top of the file.
    let script = """
      var nodes = document.querySelectorAll(
        '[data-source-line], [data-pos], [data-sourcepos]');
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        var rect = node.getBoundingClientRect();
        // Skip blocks fully above the viewport — behind the user's
        // reading position. First with bottom >= 0 is what we want.
        if (rect.bottom < 0) continue;
        var n = NaN;
        if (node.dataset.sourceLine) {
          n = parseInt(node.dataset.sourceLine, 10);
        } else {
          var raw = node.dataset.pos || node.dataset.sourcepos || '';
          var m = raw.match(/(\\d+):\\d+/);
          if (m) n = parseInt(m[1], 10);
        }
        if (Number.isNaN(n)) continue;
        return n;
      }
      return null;
      """
    do {
      let value = try await page.callJavaScript(script)
      if let number = value as? Int { return number }
      if let number = value as? Double { return Int(number) }
      if let number = value as? NSNumber { return number.intValue }
      return nil
    } catch {
      return nil
    }
  }

  // MARK: - Public entry points

  /// Inject the shared rendering appModel. Called by ContentView
  /// before the first bind. The persistent strings come from the
  /// view's `@SceneStorage` slots, so calling `bindSettings` again
  /// with new values lets state restoration drive a re-hydrate.
  /// Returns the displaced names (template, processor) when the
  /// scene-stored persistent string can't be decoded against the
  /// current catalog — caller posts the user notification.
  @discardableResult
  func bindSettings(
    _ appModel: AppModel,
    templatePersistent: String?,
    processorPersistent: String?
  ) -> (templateDisplaced: String?, processorDisplaced: String?) {
    self.appModel = appModel
    let (templates, displacedTemplate) = SceneTemplateChoice.create(
      from: appModel.templates, persistent: templatePersistent)
    self.templates = templates
    let (processors, displacedProcessor) = SceneProcessorChoice.create(
      from: appModel.processors, persistent: processorPersistent)
    self.processors = processors
    templateBox.template = resolvedTemplate()
    return (displacedTemplate, displacedProcessor)
  }

  /// Initial bind (called from ContentView's `.task(id: fileURL)`).
  /// Resets history; this URL becomes the only entry on the stack.
  ///
  /// `scrollToLine` is the source line the rendered preview should
  /// scroll to once the page finishes loading — non-nil when the open
  /// came in via `galley://...?line=N` from an editor script.
  /// `initialScrollY` hydrates the resting scroll position from the
  /// window's `@SceneStorage` slot. Both are consumed once and apply
  /// only to the first render of this bind; subsequent file-watcher
  /// reloads preserve current scroll normally. `scrollToLine` wins
  /// over `initialScrollY` if both happen to be set.
  func bind(
    to url: URL,
    scrollToLine: Int? = nil,
    initialScrollY: Double? = nil
  ) async {
    history = [url]
    currentIndex = 0
    pendingScrollLine = scrollToLine
    pendingScrollY = initialScrollY
    await rebindCurrent()
  }

  /// Restore a previously-saved history stack. Used at window
  /// re-open time to pick up where the user left off — the active
  /// document and the back/forward stack are both re-established.
  /// `initialScrollY` hydrates the resting scroll position the same
  /// way `bind` does.
  func restore(
    snapshot: HistorySnapshot,
    initialScrollY: Double? = nil
  ) async {
    guard !snapshot.urls.isEmpty,
          snapshot.currentIndex >= 0,
          snapshot.currentIndex < snapshot.urls.count
    else { return }
    history = snapshot.urls
    currentIndex = snapshot.currentIndex
    pendingScrollY = initialScrollY
    await rebindCurrent()
  }

  /// Codable view of the back/forward stack for `@SceneStorage`.
  /// Returns nil when there is nothing meaningful to persist.
  var historySnapshot: HistorySnapshot? {
    guard !history.isEmpty,
          currentIndex >= 0,
          currentIndex < history.count
    else { return nil }
    return HistorySnapshot(urls: history, currentIndex: currentIndex)
  }

  /// Push a new URL onto the history and navigate to it. Truncates
  /// any forward entries (browser-standard new-link behaviour).
  ///
  /// If the target file isn't readable, surfaces an error and leaves
  /// history, bridges, and the visible document untouched — that way
  /// a broken link click doesn't strand the window with a corrupted
  /// base URL the link bridge would resolve subsequent clicks against.
  func navigate(to url: URL) async {
    guard reportIfUnreachable(url) else { return }
    if currentIndex >= 0, currentIndex < history.count {
      history.removeSubrange((currentIndex + 1)..<history.count)
    }
    history.append(url)
    currentIndex = history.count - 1
    await rebindCurrent()
  }

  func goBack() async {
    guard canGoBack else { return }
    let target = history[currentIndex - 1]
    guard reportIfUnreachable(target) else { return }
    currentIndex -= 1
    await rebindCurrent()
  }

  func goForward() async {
    guard canGoForward else { return }
    let target = history[currentIndex + 1]
    guard reportIfUnreachable(target) else { return }
    currentIndex += 1
    await rebindCurrent()
  }

  /// Verify a link target is readable before we commit to navigating
  /// to it. Returns `true` when the file exists; otherwise sets
  /// `lastError` and returns `false`.
  private func reportIfUnreachable(_ url: URL) -> Bool {
    if FileManager.default.isReadableFile(atPath: url.path) {
      lastError = nil
      return true
    }
    lastError = "Cannot open \(url.lastPathComponent): file not found."
    NSSound.beep()
    return false
  }

  func reload() async {
    await renderCurrent(preserveScroll: true)
  }

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
      jobTitle: documentURL?.lastPathComponent ?? "Markdown Document",
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
        jobTitle: documentURL?.lastPathComponent ?? "Markdown Document",
        on: window
      ) { operation, _ in
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
      }
      lastError = nil
    } catch {
      logger.error("""
        print failed: \(error.localizedDescription, privacy: .public)
        """)
      lastError = error.localizedDescription
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
  private func runPrintOperation(
    jobTitle: String,
    on window: NSWindow?,
    configure: (NSPrintOperation, NSPrintInfo) -> Void
  ) async throws {
    let html = try await buildRenderedHTML()
    let template = resolvedTemplate()

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
      html: html, template: template, paperSize: baseInfo.paperSize)

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
    html: String,
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
      webView.loadHTMLString(html, baseURL: PreviewSchemeHandler.originURL)
    }
  }

  /// Build the rendered HTML the print/export web view loads — same
  /// pipeline `renderCurrent` uses, minus the live-zoom style. Print
  /// renders at 100 % regardless of the on-screen zoom factor.
  private func buildRenderedHTML() async throws -> String {
    guard let url = documentURL else {
      throw CocoaError(.fileNoSuchFile)
    }
    let renderer = resolvedRenderer()
    let template = resolvedTemplate()
    let source = try String(contentsOf: url, encoding: .utf8)
    let body = try await renderer.render(source, baseURL: url)
    let templateHTML = try template.loadHTML()
    let origin = PreviewSchemeHandler.originURL
    let context = PlaceholderContext(
      documentContent: body,
      documentURL: url,
      origin: origin)
    let substituted = context.substitute(into: templateHTML)
    return template.rewriteAssets(in: substituted, origin: origin)
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

  // MARK: - Zoom

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
  private func applyZoomToPage() async {
    let css = "html{zoom:\(pageZoom);}"
    let script = """
      (function(){
        var s = document.getElementById('md-eye-zoom');
        if (!s) {
          s = document.createElement('style');
          s.id = 'md-eye-zoom';
          document.head.appendChild(s);
        }
        s.textContent = \(jsStringLiteral(css));
      })();
      """
    _ = try? await page.callJavaScript(script)
  }

  /// Embed the current zoom as a `<style>` element in the rendered
  /// HTML so the page comes up at the right size on the very first
  /// frame — applying via JS after load would briefly flash at 100%.
  private func injectZoomStyle(into html: String) -> String {
    let style = "<style id=\"md-eye-zoom\">html{zoom:\(pageZoom);}</style>"
    if let range = html.range(
      of: "</head>", options: .caseInsensitive)
    {
      return html.replacingCharacters(in: range, with: style + "</head>")
    }
    return style + html
  }

  /// Rename the current document on disk and re-bind the watcher /
  /// bridges to the new path. History entries that point at the old
  /// URL are rewritten in place so Back/Forward stays correct.
  /// Returns the new URL on success; throws if the move fails (the
  /// caller is expected to revert the title binding in that case).
  @discardableResult
  func renameCurrentDocument(toName newName: String) async throws -> URL {
    guard let oldURL = documentURL else {
      throw CocoaError(.fileNoSuchFile)
    }
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.contains("/"),
          trimmed != oldURL.lastPathComponent
    else { return oldURL }

    let newURL = oldURL.deletingLastPathComponent()
      .appendingPathComponent(trimmed)
    do {
      try FileManager.default.moveItem(at: oldURL, to: newURL)
    } catch {
      lastError = "Rename failed: \(error.localizedDescription)"
      throw error
    }
    lastError = nil

    // Patch every history entry that referenced the old URL — Back
    // would otherwise lead to a now-missing path and trip the
    // unreachable-link guard.
    history = history.map { $0 == oldURL ? newURL : $0 }
    await rebindCurrent()
    return newURL
  }

  // MARK: - Internals

  /// Rebind the model to whichever URL is at `currentIndex`. Drives
  /// the initial render and keeps reloading on file changes until
  /// another rebind supersedes this one.
  private func rebindCurrent() async {
    guard currentIndex >= 0, currentIndex < history.count else { return }
    let url = history[currentIndex]

    bindGeneration &+= 1
    let myGeneration = bindGeneration
    logger.debug("Binding to document: \(url.path, privacy: .public)")
    documentURL = url
    bridge.documentURL = url
    linkBridge.documentURL = url

    await renderCurrent(preserveScroll: false)

    let stream = await watcher.subscribe(to: url)
    for await _ in stream {
      if Task.isCancelled || bindGeneration != myGeneration { break }
      // Keep the user's place when the file changes on disk —
      // re-rendering otherwise snaps the WebView back to the top.
      await renderCurrent(preserveScroll: true)
    }
  }

  private func renderCurrent(preserveScroll: Bool) async {
    guard let url = documentURL else {
      logger.warning("renderCurrent() called with no documentURL")
      return
    }
    let renderer = resolvedRenderer()
    let template = resolvedTemplate()
    // Keep the scheme handler's template pointer current — the user
    // may have switched templates since the last bind.
    templateBox.template = template

    // Snapshot scroll position *before* re-rendering so we can hand it
    // back to the page after load. Best-effort: a nil/throwing read
    // (e.g. very first render) just leaves us at the top.
    let savedScrollY: Double = preserveScroll
      ? await currentScrollY() ?? 0
      : 0

    do {
      let source = try String(contentsOf: url, encoding: .utf8)
      let body = try await renderer.render(source, baseURL: url)
      let templateHTML = try template.loadHTML()
      let origin = PreviewSchemeHandler.originURL
      let context = PlaceholderContext(
        documentContent: body,
        documentURL: url,
        origin: origin)
      let substituted = context.substitute(into: templateHTML)
      let rewritten = template.rewriteAssets(in: substituted, origin: origin)
      let html = injectZoomStyle(into: rewritten)
      logger.debug("Loading rendered HTML (\(html.count) bytes)")
      do {
        for try await _ in page.load(html: html, baseURL: origin) {}
        lastError = nil
        if let line = pendingScrollLine {
          // One-shot — consume before the JS call so an in-flight
          // file-watcher reload doesn't re-jump.
          pendingScrollLine = nil
          pendingScrollY = nil
          await scrollToSourceLine(line)
        } else if let y = pendingScrollY {
          pendingScrollY = nil
          if y > 0 {
            currentScrollY = y
            await restoreScrollY(y)
          }
        } else if savedScrollY > 0 {
          await restoreScrollY(savedScrollY)
        }
      } catch {
        logger.error("""
          Navigation failed: \(error.localizedDescription, privacy: .public)
          """)
        lastError = error.localizedDescription
      }
    } catch {
      logger.error("""
        render failed: \(error.localizedDescription, privacy: .public)
        """)
      lastError = error.localizedDescription
    }
  }

  /// Resolve the renderer for the next render. When the per-document
  /// override flag is on, the window-local choice wins (falling back
  /// to the global selection if its pick is unavailable). Otherwise
  /// always use the global selection.
  private func resolvedRenderer() -> any MarkdownRenderer {
    if appModel?.enablePerDocumentOverrides == true,
       let processors,
       let renderer = processors.selected.value.renderer
    {
      return renderer
    }
    return appModel?.activeRenderer ?? SwiftMarkdownRenderer()
  }

  private func resolvedTemplate() -> Template {
    if appModel?.enablePerDocumentOverrides == true,
       let templates
    {
      return templates.selected.value
    }
    return appModel?.activeTemplate ?? .default
  }

  private func currentScrollY() async -> Double? {
    do {
      let value = try await page.callJavaScript("return window.scrollY;")
      if let number = value as? Double { return number }
      if let number = value as? NSNumber { return number.doubleValue }
      return nil
    } catch {
      return nil
    }
  }

  private func restoreScrollY(_ yPos: Double) async {
    _ = try? await page.callJavaScript("window.scrollTo(0, \(yPos));")
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
}

/// Escape a Swift string into a JavaScript double-quoted string
/// literal. Only used for a CSS rule we control, but kept strict so
/// future zoom-related callers can pass arbitrary text safely.
private func jsStringLiteral(_ value: String) -> String {
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

/// Reference holder so the URL scheme handler — which captures the
/// box at WebPage creation time, before appModel are injected —
/// always sees the latest template. DocumentModel updates `template`
/// in `bindSettings(_:)` and at the start of every render.
@MainActor
final class TemplateBox {
  var template: Template?
}

/// Serializable form of a window's back/forward stack. Persisted via
/// `@SceneStorage` so each window restores to whichever document the
/// user was viewing when the app last quit.
struct HistorySnapshot: Codable, Sendable, Equatable {
  let urls: [URL]
  let currentIndex: Int
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
