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
  @ObservationIgnored private let tocBridge = TOCBridge()
  @ObservationIgnored private let backgroundBridge = BackgroundColorBridge()
  @ObservationIgnored private let appModel: AppModel
  @ObservationIgnored private let templateBox: TemplateBox

  /// Computed background color of the rendered page (`html` or
  /// `body`), reported by `BackgroundColorBridge` after each render.
  /// `DocumentView` paints this into the window's container
  /// background so translucent toolbar and sidebar chrome show a
  /// matching tint — the illusion that the document extends
  /// edge-to-edge.
  ///
  /// The page background color of the currently-resolved template.
  /// Reads through `Template.backgroundColor` (which is itself a
  /// computed view onto `Defaults.shared.templateBackgroundColors`),
  /// so this property is reactive *and* the cache is automatically
  /// shared across all DocumentModels using the same template — no
  /// per-instance state needed. `nil` only for templates that have
  /// never been rendered (a one-time flash on a brand-new template).
  var pageBackgroundColor: Color? {
    resolvedTemplate().backgroundColor
  }

  /// Per-window template / processor choices. Reference types so
  /// SwiftUI's Observation tracks `selected` for menus that bind to
  /// them. Constructed at init with the per-file persisted IDs (or
  /// `nil` for "use the global selection"); the `persistent` setter
  /// later picks up overrides discovered during state restoration.
  let templates: SceneTemplateChoice
  let processors: SceneProcessorChoice

  /// The URL the model is currently bound to. Set at construction
  /// from the WindowGroup's URL and updated synchronously at the
  /// start of every `rebindCurrent` (in-window navigation, restore,
  /// rename, reload). Render-state visibility is tracked separately
  /// by `didFirstBind`.
  private(set) var documentURL: URL
  var lastError: String?

  /// Set to `true` at the start of the first `rebindCurrent` call.
  /// Distinguishes "model exists, has a URL, but render hasn't been
  /// triggered yet" from "render has begun." DocumentView uses this
  /// to gate window-reveal alpha and to short-circuit duplicate
  /// `.task(id:)` fires from triggering re-binds.
  private(set) var didFirstBind: Bool = false

  /// True once the WebView has finished painting the *current* bind's
  /// HTML (signalled by the BackgroundColorBridge firing post-layout).
  /// Reset to `false` at the start of every rebind so DocumentView can
  /// overlay the WebView's empty white canvas with `pageBackgroundColor`
  /// during the brief mount→render window — the cause of the visible
  /// "white flash inside the WebView rectangle" on tab open / reload.
  /// Per-bind, not per-model: the flag toggles on every navigation.
  private(set) var isPageRendered: Bool = false

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

  /// Whether the table-of-contents sidebar is visible in the window
  /// hosting this model. Per-document live state — preserved across
  /// in-window link navigation so a child doc inherits the parent's
  /// pick. Cold opens / Replace-current rebinds reset this from the
  /// destination URL's `PerFileStateStore` entry instead.
  var showsTOC: Bool = false

  /// Headings extracted from the rendered DOM after each load. The
  /// `TOCBridge` user script walks `<h1>…<h6>`, assigns synthetic ids
  /// to any heading without one, and posts the flat list. The
  /// sidebar reads this and indents by `level`.
  private(set) var headings: [TOCEntry] = []

  /// Id of the heading whose section the reader is currently in,
  /// updated by `TOCBridge` on scroll. `nil` means the user is
  /// scrolled above the first heading. The sidebar highlights the
  /// matching row.
  private(set) var activeHeadingID: String?

  /// Whether the find-text bar is showing in the window hosting this
  /// model. Per-document; not persisted across launches.
  var isFindVisible: Bool = false

  /// Live find query. Edits trigger an immediate `performFind` from
  /// the find bar's `.onChange`.
  var findQuery: String = ""

  /// Number of matches found by the latest `performFind` against the
  /// rendered DOM. Drives the "n of N" count in the find bar.
  var findMatchCount: Int = 0

  /// Zero-based index of the currently-highlighted match, or `-1`
  /// when there is nothing highlighted (empty query / no matches).
  var findMatchIndex: Int = -1

  /// When true, find matches are case-sensitive. Defaults off to
  /// match Preview / Safari behavior — most users expect case-
  /// insensitive find.
  var findCaseSensitive: Bool = false

  /// When true, find only matches whole words (regex `\b…\b`).
  /// ASCII-boundary based — sufficient for the Latin-script content
  /// the viewer most often renders.
  var findWholeWord: Bool = false

  /// Monotonic token bumped when an external surface (toolbar
  /// `Action.toggleFind`, View menu) requests the find bar to dismiss.
  /// `FindBar` observes this so it can drop focus before the slide-out
  /// transition starts — otherwise the focus ring renders over content
  /// the bar slides past. Direct `model.hideFind()` is the unanimated
  /// path; this token is the animated, focus-aware path.
  var findDismissalToken: Int = 0

  let logger = Logger(
    subsystem: bundleIdentifier, category: "DocumentModel")

  init(
    initialURL: URL,
    appModel: AppModel,
    templatePersistent: String?,
    processorPersistent: String?
  ) {
    self.documentURL = initialURL
    self.history = [initialURL]
    self.currentIndex = 0
    self.appModel = appModel
    self.templates = SceneTemplateChoice(
      source: appModel.templates,
      persistent: templatePersistent
    ) { name in
      DisplacementNotifier.post(kind: .template, displaced: name)
    }
    self.processors = SceneProcessorChoice(
      source: appModel.processors,
      persistent: processorPersistent
    ) { name in
      DisplacementNotifier.post(kind: .processor, displaced: name)
    }

    let box = TemplateBox()
    self.templateBox = box
    self.page = WebPage(configuration: Self.makeConfiguration(
      editorBridge: bridge,
      linkBridge: linkBridge,
      scrollBridge: scrollBridge,
      tocBridge: tocBridge,
      backgroundBridge: backgroundBridge,
      templateBox: box))
    // Seed the scheme handler's template pointer. `renderCurrent`
    // updates it again on every render — this seed only matters for
    // asset requests that might fire before the first render.
    self.templateBox.template = resolvedTemplate()

    wireBridges()
  }

  /// Build the `WebPage.Configuration`: register every script-message
  /// handler, inject the user scripts each bridge needs, and wire the
  /// custom URL scheme that resolves template-bundled assets through
  /// `templateBox`. Static so it can run before `self` is fully
  /// initialized; pure plumbing — no closures capture the model.
  private static func makeConfiguration(
    editorBridge: EditorBridge,
    linkBridge: LinkBridge,
    scrollBridge: ScrollBridge,
    tocBridge: TOCBridge,
    backgroundBridge: BackgroundColorBridge,
    templateBox: TemplateBox
  ) -> WebPage.Configuration {
    var configuration = WebPage.Configuration()
    let controller = configuration.userContentController
    controller.add(editorBridge, name: EditorBridge.messageName)
    controller.add(linkBridge, name: LinkBridge.messageName)
    controller.add(scrollBridge, name: ScrollBridge.messageName)
    controller.add(tocBridge, name: TOCBridge.messageName)
    controller.add(
      backgroundBridge, name: BackgroundColorBridge.messageName)
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
    // Heading extraction. Runs once per load, assigns synthetic ids
    // to headings that lack one, and posts the list back. Renderer-
    // agnostic — every Markdown processor we ship outputs `<h1>…<h6>`.
    controller.addUserScript(WKUserScript(
      source: TOCBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Computed background-color reader. Runs after layout so the
    // host can paint a matching tint behind translucent chrome.
    controller.addUserScript(WKUserScript(
      source: BackgroundColorBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Find-text controller. The style script runs at document-start
    // so the highlight CSS is in place before any match is wrapped;
    // the controller script runs at document-end so `document.body`
    // exists when `window.galleyFind` is wired up.
    controller.addUserScript(WKUserScript(
      source: FindBridge.styleScript,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true))
    controller.addUserScript(WKUserScript(
      source: FindBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Custom URL scheme so template-bundled assets (CSS, fonts,
    // images) resolve from disk through the SwiftUI WebView. Reads
    // the active template at request time via `templateBox`, kept
    // current by `renderCurrent` on every render.
    let handler = PreviewSchemeHandler(
      templateProvider: { templateBox.template ?? .default })
    configuration.urlSchemeHandlers[PreviewSchemeHandler.scheme] = handler
    return configuration
  }

  /// Attach `[weak self]` callbacks to each bridge. Lifted out of
  /// `init` so the constructor stays under SwiftLint's body-length
  /// budget; called once, immediately after `self` is fully
  /// initialized.
  private func wireBridges() {
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
    scrollBridge.onScroll = { [weak self] yPos in
      guard let self else { return }
      currentScrollY = yPos
    }
    tocBridge.onHeadings = { [weak self] items in
      guard let self else { return }
      headings = items
    }
    tocBridge.onActiveHeading = { [weak self] identifier in
      guard let self else { return }
      activeHeadingID = identifier
    }
    backgroundBridge.onColor = { [weak self] color in
      guard let self else { return }
      // Bridge fires post-layout regardless of whether the page
      // declared an opaque bg, so any fire = "WebView has painted"
      // and we can drop DocumentView's anti-flash overlay.
      isPageRendered = true
      // Treat the bridge's `nil` (page declared no opaque bg) as
      // "keep showing what we already have" — leaving the previous
      // template-keyed entry intact means in-window navigation
      // between docs that don't override bg won't flash.
      guard let color else { return }
      // Persist to the template's slot in `Defaults.shared
      // .templateBackgroundColors`. Every other DocumentModel using
      // this template observes the change automatically through
      // their own `pageBackgroundColor` computed property.
      resolvedTemplate().setBackgroundColor(color)
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
    let url = documentURL
    let resolvedLine: Int?
    if let line {
      resolvedLine = line
    } else {
      resolvedLine = await topmostVisibleSourceLine()
    }
    await openFileInEditor(
      appModel.editors.selected,
      fileURL: url,
      line: resolvedLine,
      logger: logger)
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

  /// Initial bind (called from DocumentView's `.task`).
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
    initialScrollY: Double? = nil,
    initialShowsTOC: Bool? = nil
  ) async {
    history = [url]
    currentIndex = 0
    pendingScrollLine = scrollToLine
    pendingScrollY = initialScrollY
    if let initialShowsTOC { showsTOC = initialShowsTOC }
    await rebindCurrent()
  }

  /// Restore a previously-saved history stack. Used at window
  /// re-open time to pick up where the user left off — the active
  /// document and the back/forward stack are both re-established.
  /// `initialScrollY` hydrates the resting scroll position the same
  /// way `bind` does.
  func restore(
    snapshot: HistorySnapshot,
    initialScrollY: Double? = nil,
    initialShowsTOC: Bool? = nil
  ) async {
    guard !snapshot.urls.isEmpty,
          snapshot.currentIndex >= 0,
          snapshot.currentIndex < snapshot.urls.count
    else { return }
    history = snapshot.urls
    currentIndex = snapshot.currentIndex
    pendingScrollY = initialScrollY
    if let initialShowsTOC { showsTOC = initialShowsTOC }
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
    // `pageBackgroundColor` is now computed off `resolvedTemplate()
    // .backgroundColor`, which reads through Defaults — so a
    // template change automatically flips the chrome to the new
    // template's cached color before the WebView re-renders.
    // Reset `isPageRendered` so DocumentView's anti-flash overlay
    // covers the WebView until the bridge confirms paint commits.
    isPageRendered = false
    await renderCurrent(preserveScroll: true)
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
    let oldURL = documentURL
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
    logBinding(to: url)
    documentURL = url
    didFirstBind = true
    // The WebView's pre-paint canvas is system-white regardless of
    // CSS — clear the rendered flag so DocumentView can mask that
    // gap with the cached page bg until BackgroundColorBridge
    // reports a fresh post-layout color.
    isPageRendered = false
    bridge.documentURL = url
    linkBridge.documentURL = url
    // Drop the old document's TOC entries so the sidebar doesn't
    // flash stale headings during the reload window. The TOCBridge
    // user script repopulates within milliseconds of `page.load`.
    headings = []
    activeHeadingID = nil

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
    let url = documentURL
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
      let composed = try template.composeHTML(
        documentContent: body,
        documentURL: url,
        origin: PreviewSchemeHandler.originURL)
      let html = injectZoomStyle(into: composed.html)
      logLoadingHTML(byteCount: html.count)
      do {
        for try await _ in page.load(html: html, baseURL: composed.baseURL) {}
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
        // Old marks died with the previous DOM, but the user's query
        // and the visible find bar are per-window state we want to
        // honor across file-watcher reloads — re-run the search so
        // highlights and counts come back without user action.
        if isFindVisible, !findQuery.isEmpty {
          await performFind()
        }
      } catch {
        logNavigationFailed(error)
        lastError = error.localizedDescription
      }
    } catch {
      logRenderFailed(error)
      lastError = error.localizedDescription
    }
  }

  // MARK: - Logging helpers

  private func logBinding(to url: URL) {
    logger.debug("Binding to document: \(url.path, privacy: .public)")
  }

  private func logLoadingHTML(byteCount: Int) {
    logger.debug("Loading rendered HTML (\(byteCount) bytes)")
  }

  private func logNavigationFailed(_ error: any Error) {
    logger.error("""
      Navigation failed: \(error.localizedDescription, privacy: .public)
      """)
  }

  private func logRenderFailed(_ error: any Error) {
    logger.error("""
      render failed: \(error.localizedDescription, privacy: .public)
      """)
  }

  /// Resolve the renderer for the next render. When the per-document
  /// override flag is on, the window-local choice wins (falling back
  /// to the global selection if its pick is unavailable). Otherwise
  /// always use the global selection.
  func resolvedRenderer() -> any MarkdownRenderer {
    if Defaults.shared.enablePerDocumentOverrides == true,
       let renderer = processors.selected.value.renderer
    {
      return renderer
    }

    return appModel.processors.selected.value.renderer
    ?? SwiftMarkdownRenderer()
  }

  func resolvedTemplate() -> Template {
    if Defaults.shared.enablePerDocumentOverrides == true {
      return templates.selected.value
    }
    return appModel.templates.selected.value
  }

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

  /// The URL the snapshot says the window was last viewing, or `nil`
  /// when `currentIndex` is out of range (corrupted store).
  var currentURL: URL? {
    urls.indices.contains(currentIndex) ? urls[currentIndex] : nil
  }
}
