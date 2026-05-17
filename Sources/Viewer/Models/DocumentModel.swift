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
  /// Distinguishes a normal document window from the singleton Help
  /// window. Help mode skips the routing-registry handshake (adopt /
  /// unregister / updateCurrentURL) so help windows are invisible to
  /// the URL dispatcher — they're never tab-merge targets, never
  /// focus-existing targets, never rebind targets. `record(_:)` on
  /// `RecentDocumentsModel` independently refuses bundle URLs, so
  /// the inline `recents.record(...)` calls below are no-ops in help
  /// mode without needing a conditional.
  enum Kind {
    case document
    case help
  }

  let page: WebPage
  let kind: Kind

  @ObservationIgnored private let watcher = DocumentWatcher()
  @ObservationIgnored private let bridge = EditorBridge()
  @ObservationIgnored private let linkBridge = LinkBridge()
  @ObservationIgnored private let scrollBridge = ScrollBridge()
  @ObservationIgnored private let tocBridge = TOCBridge()
  @ObservationIgnored private let statsBridge = StatsBridge()
  @ObservationIgnored private let backgroundBridge = BackgroundColorBridge()
  @ObservationIgnored let appModel: AppModel
  @ObservationIgnored private let templateBox: TemplateBox

  /// Chrome reads through this. Drives off `renderedTemplate()` —
  /// the template *actually painted* in the WebView right now — so
  /// the chrome stays at the previous color through a template
  /// switch (when the selected template has flipped to the new one
  /// but the WebView still shows the old HTML) and snaps to the new
  /// color in a single frame when the bridge confirms the new
  /// render. Reading `resolvedTemplate()` here instead would flash
  /// the new template's cached color the instant the user picks it,
  /// then flash back when the bridge corrects the cache after the
  /// outgoing page's last (stale) post — the "sepia then dark then
  /// sepia" flicker that motivated this refactor.
  var pageBackgroundColor: Color {
    renderedTemplate().backgroundState.color
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

  /// Single user-visible error / status channel. Replaces the prior
  /// scattered `lastError = …` writes. `nil` means "no notice." Set
  /// via `report(_:lifetime:)` / `report(failure:context:lifetime:)`;
  /// cleared by `dismissNotice()` (banner close), the auto-clear
  /// timer (for `.ephemeral`), or `clearRenderBoundNotice()` at the
  /// start of every render (for `.renderBound` — so a stale render
  /// failure doesn't outlive its bind, but an in-flight ephemeral
  /// receipt for a separate action is left alone). Set-access stays
  /// open so the `+Notice` extension can manage state; readers should
  /// not mutate directly.
  var notice: DocumentNotice?

  /// Auto-clear task for ephemeral notices. Cancelled when a new
  /// notice arrives or when the user manually dismisses, so old
  /// timers can't blow away a fresher notice. Owned by the `+Notice`
  /// extension; nothing else writes it.
  @ObservationIgnored var ephemeralClearTask: Task<Void, Never>?

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

  /// True from the moment the user (or a global selection change)
  /// switches this window to a *different* template, until the
  /// bridge confirms the new render has painted. While true,
  /// DocumentView pins the scene's `preferredColorScheme` to the
  /// user's system pref instead of the previous template's
  /// bg-luminance-derived scheme — without that override WebKit's
  /// `prefers-color-scheme` media queries on the new template
  /// would pick whichever variant was current under the *previous*
  /// template (e.g. switching from Terminal-dark to a media-query
  /// template would render the dark variant even when the user is
  /// in light mode).
  private(set) var isRenderingNewTemplate: Bool = false

  /// `Template.persistentID` of the template that produced the
  /// most-recently-painted render — the one the WebView is currently
  /// displaying, identified by the `galley-template-id` meta the
  /// composer injects and the JS reader echoes back. Drives
  /// `renderedTemplate()` (which `pageBackgroundColor` and the chrome
  /// read), and `reload()` compares against `resolvedTemplate()
  /// .persistentID` to decide whether the scheme reset is needed.
  ///
  /// Observed — SwiftUI re-evaluates the chrome's container
  /// background, scheme, and overlay color the moment this flips.
  private(set) var renderedTemplateID: String?

  /// Page zoom factor for the rendered preview. Applied via a CSS
  /// `zoom` rule injected into the document head; updated live via JS
  /// when the user changes it without re-rendering.
  var pageZoom: Double = 1.0

  /// Discrete zoom stops, matching what Safari and Preview offer so
  /// repeated ⌘+ presses land on familiar values.
  static let zoomStops: [Double] = [
    0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0
  ]
  static let minZoom: Double = 0.5
  static let maxZoom: Double = 3.0

  var canZoomIn: Bool { pageZoom < Self.maxZoom - 0.001 }
  var canZoomOut: Bool { pageZoom > Self.minZoom + 0.001 }
  var canResetZoom: Bool { abs(pageZoom - 1.0) > 0.001 }

  /// Visited documents in chronological order; `currentIndex` points
  /// at the one currently rendered. Navigation actions move
  /// `currentIndex` and rebind without truncating the stack — so
  /// pressing Forward after Back works. Mutated by the History
  /// extension's `navigate`/`goBack`/`goForward` and by `rename`.
  var history: [URL] = []
  var currentIndex: Int = -1

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
  ///
  /// Starts `true` so `NavigationSplitView` is born with a visible
  /// sidebar — AppKit only wires `NSSplitViewItem.behavior = .sidebar`
  /// when the column is visible at first paint, otherwise a later
  /// toggle puts sidebar content below the tab bar instead of
  /// extending up under it. `BeforeFirstDrawAccessor` collapses it
  /// pre-paint when `savedShowsTOC` says the user wanted it closed.
  var showsTOC: Bool = true

  /// One-shot guard for the pre-first-draw sidebar collapse. `false`
  /// means "the user wanted TOC closed for this bind — collapse on
  /// the next `viewWillDraw`." `true` means "leave the sidebar
  /// alone" (either the user wants it open, or we've already
  /// applied the collapse). Set by `finishBind` from the bind's
  /// `initialShowsTOC` and consumed by `BeforeFirstDrawAccessor`.
  @ObservationIgnored var savedShowsTOC: Bool = true

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

  /// Word / character / heading counts for the rendered document,
  /// refreshed by `StatsBridge` after each load. Drives the
  /// optional bottom `StatusBar`. Reset to `.empty` at the start of
  /// every rebind so a stale count doesn't linger while the next
  /// render is in flight.
  private(set) var stats: DocumentStats = .empty

  /// Find-text state and JS calls for this window. Owns the query,
  /// options, match counters, and visibility / dismissal flags.
  /// Constructed once `page` is built so it can drive
  /// `window.galleyFind` directly. `SearchModel`-conforming so the
  /// `FindBar` view can `@Bindable` it.
  let find: FindSession

  /// Whether the SwiftUI `.fileExporter` for "Export as PDF" is
  /// presented. Flipped by `requestExportPDF()` (typically from the
  /// File menu); SwiftUI flips it back on completion or cancellation.
  /// Lives on the model so the menu can reach it through the existing
  /// `\.documentModel` focused value without a dedicated context type.
  var isExportingPDF: Bool = false

  /// Whether the SwiftUI rename alert is presented. Same rationale
  /// as `isExportingPDF` — keeps the menu → focused-window bridge
  /// to a single focused value. The alert's text-field value is
  /// view-local `@State` on `DocumentView`, seeded via `.onChange`
  /// when this flips true.
  var isRenameRequested: Bool = false

  let logger = Logger(
    subsystem: bundleIdentifier, category: "DocumentModel")

  /// Per-document color-scheme override slot. `nil` means "use the
  /// global default" (`Defaults.shared.documentColorScheme`, visionOS
  /// only). Gated by `enablePerDocumentOverrides` at read time the
  /// same way template/processor per-doc choices are. macOS does
  /// not surface this — it tracks the system appearance directly —
  /// but the field exists in shared code so the constructor stays
  /// uniform.
  var documentColorScheme: DocumentColorScheme?

  init(
    initialURL: URL,
    appModel: AppModel,
    templatePersistent: String?,
    processorPersistent: String?,
    documentColorSchemePersistent: DocumentColorScheme? = nil,
    kind: Kind
  ) {
    self.kind = kind
    self.documentURL = initialURL
    self.history = [initialURL]
    self.currentIndex = 0
    self.appModel = appModel
    self.documentColorScheme = documentColorSchemePersistent
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
    self.page = WebPage(
      configuration: Self.makeConfiguration(
        editorBridge: bridge,
        linkBridge: linkBridge,
        scrollBridge: scrollBridge,
        tocBridge: tocBridge,
        statsBridge: statsBridge,
        backgroundBridge: backgroundBridge,
        templateBox: box),
      // Pin the Galley Server HTTPS cert. Most loads are
      // in-process via `x-galley://local`, but any HTTPS asset that
      // resolves to the server (template-rewritten URLs, future
      // server-driven loads) gets validated against
      // `server-cert.pem` instead of the user's keychain.
      navigationDecider: ServerCertificatePinner())
    self.find = FindSession(page: self.page)
    // Seed the scheme handler's template pointer. `renderCurrent`
    // updates it again on every render — this seed only matters for
    // asset requests that might fire before the first render.
    self.templateBox.template = resolvedTemplate()

    wireBridges()
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
    statsBridge.onStats = { [weak self] value in
      guard let self else { return }
      stats = value
    }
    backgroundBridge.onColor = { [weak self] color, templateID in
      guard let self else { return }
      // Bridge fires post-layout regardless of whether the page
      // declared an opaque bg, so any fire = "WebView has painted"
      // and we can drop DocumentView's anti-flash overlay.
      isPageRendered = true
      isRenderingNewTemplate = false
      // Attribute the post to the template that's actually painted
      // in the WebView, identified by the `galley-template-id` meta
      // the composer injected (echoed back by the JS reader). When
      // that template is no longer in the catalog (uninstalled
      // mid-render — extremely rare), fall back to the selected
      // template; better a slightly-stale write than no write.
      let painted = templateID.flatMap {
        appModel.templates.findValue(forID: $0)
      } ?? resolvedTemplate()
      renderedTemplateID = painted.persistentID
      // Always persist — `color: nil` records a sentinel so a
      // template that *used to* paint a bg but no longer does (CSS
      // edited) overwrites its stale hex entry. Every other
      // DocumentModel using this template observes the change
      // through their own `pageBackgroundColor` computed property.
      painted.setBackgroundColor(color)
    }
  }

  /// Open the current document in the user's chosen editor.
  /// `line` is non-nil for cmd-click on a `data-source-line` block.
  /// When nil (File > Open in Editor), we try to land the editor on
  /// the source line the user is currently reading by querying the
  /// topmost visible position-tagged block in the WebView; falls
  /// back to opening at the file with no line if the active renderer
  /// emits no source positions.
  ///
  /// macOS-only: external editors (BBEdit / VS Code / Xcode / …) are
  /// not a visionOS concept. On non-macOS this is a no-op so callers
  /// (cmd-click bridge handler, File > Open in Editor menu item)
  /// don't need to platform-guard at the call site.
  func openInEditor(line: Int? = nil) async {
    #if os(macOS)
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
    #else
    _ = line
    #endif
  }

  /// Find the smallest source line of any block currently in (or
  /// just above) the viewport. Reads the same three attribute
  /// flavors `EditorBridge` understands. Returns nil if the active
  /// renderer doesn't emit source positions, or if no positioned
  /// block is visible (very short docs, mostly).
  ///
  /// Script source lives in
  /// `Resources/Scripts/topmostVisibleSourceLine.js`. `callJavaScript`
  /// wraps it in an async function and captures a top-level `return`,
  /// so the script must NOT be wrapped in an IIFE.
  private static let topmostVisibleSourceLineScript: String =
    Bundle.main.requiredString(
      forResource: "topmostVisibleSourceLine", withExtension: "js")

  private func topmostVisibleSourceLine() async -> Int? {
    do {
      let value = try await page.callJavaScript(
        Self.topmostVisibleSourceLineScript)
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
    pendingScrollLine = scrollToLine
    await finishBind(
      urls: [url],
      currentIndex: 0,
      initialScrollY: initialScrollY,
      initialShowsTOC: initialShowsTOC)
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
    await finishBind(
      urls: snapshot.urls,
      currentIndex: snapshot.currentIndex,
      initialScrollY: initialScrollY,
      initialShowsTOC: initialShowsTOC)
  }

  private func finishBind(
    urls: [URL],
    currentIndex: Int,
    initialScrollY: Double?,
    initialShowsTOC: Bool?) async
  {
    history = urls
    self.currentIndex = currentIndex
    pendingScrollY = initialScrollY
    // Stash the desired sidebar state for `BeforeFirstDrawAccessor`
    // to apply pre-first-paint. `showsTOC` itself stays `true` so
    // NavigationSplitView is born with the sidebar visible and
    // AppKit wires `NSSplitViewItem.behavior = .sidebar` — without
    // that, a later toggle puts sidebar content below the tab bar.
    savedShowsTOC = initialShowsTOC ?? false
    await rebindCurrent()
  }

  func reload() async {
    // `pageBackgroundColor` is computed off `renderedTemplate()
    // .backgroundState`, so the chrome stays at the *current* painted
    // template's color through the entire render — no optimistic
    // flash to the incoming template's cached color, no flash back
    // when the bridge corrects it.
    //
    // Detect template-change by comparing the selected (next) id
    // against the currently-painted id: when they differ, set
    // `isRenderingNewTemplate` so DocumentView pins the scene scheme
    // to the user's system pref. Without that, WebKit's
    // `prefers-color-scheme` queries inside the new template would
    // resolve under whatever scheme the previous template's
    // bg-luminance forced — and pick the wrong variant.
    let nextTemplateID = resolvedTemplate().persistentID
    if nextTemplateID != renderedTemplateID {
      isRenderingNewTemplate = true
    }
    isPageRendered = false
    await renderCurrent(preserveScroll: true)
  }

  /// Rename the current document on disk and re-bind the watcher /
  /// bridges to the new path. History entries that point at the old
  /// URL are rewritten in place so Back/Forward stays correct.
  /// Returns the new URL on success; throws if the move fails (the
  /// caller is expected to revert the title binding in that case).
  @discardableResult
  func renameCurrentDocument(toName newName: String) async throws -> URL {
    let oldURL = documentURL
    guard oldURL.isFileURL else {
      // Remote documents have no on-disk presence to rename. Surface
      // a notice so a stray menu trigger gives feedback instead of
      // failing silently.
      report(
        String(localized: "Remote documents can’t be renamed."),
        lifetime: .ephemeral)
      return oldURL
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
      report(
        failure: error, context: "rename",
        message: String(localized:
          "Rename failed: \(error.localizedDescription)"),
        lifetime: .ephemeral)
      throw error
    }

    // Patch every history entry that referenced the old URL — Back
    // would otherwise lead to a now-missing path and trip the
    // unreachable-link guard.
    history = history.map { $0 == oldURL ? newURL : $0 }
    await rebindCurrent()
    return newURL
  }

  /// Present the SwiftUI rename alert. Triggered by the File ▸
  /// Rename… menu. The view seeds its text-field `@State` from
  /// `documentURL.lastPathComponent` on this transition.
  func requestRename() {
    isRenameRequested = true
  }

  /// Present the SwiftUI `.fileExporter` for "Export as PDF". The
  /// render closure on `pdfExport` is invoked by SwiftUI only after
  /// the user picks a destination — cancelling does no work.
  func requestExportPDF() {
    isExportingPDF = true
  }

  // MARK: - Internals

  /// Rebind the model to whichever URL is at `currentIndex`. Drives
  /// the initial render and keeps reloading on file changes until
  /// another rebind supersedes this one.
  func rebindCurrent() async {
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
    stats = .empty

    await renderCurrent(preserveScroll: false)

    // Only file URLs get a live-reload subscription. Remote
    // documents have no FSEvents source — the user reloads
    // manually via the Reload command.
    guard url.isFileURL else { return }

    let stream = await watcher.subscribe(to: url)
    for await _ in stream {
      if Task.isCancelled || bindGeneration != myGeneration { break }
      // Keep the user's place when the file changes on disk —
      // re-rendering otherwise snaps the WebView back to the top.
      await renderCurrent(preserveScroll: true)
    }
  }

  private func renderCurrent(preserveScroll: Bool) async {
    // Drop any prior render-bound notice — it described the previous
    // bind and would otherwise sit behind the incoming render until
    // the next failure overwrote it. Leaves an in-flight ephemeral
    // notice (e.g. a broken-link beep banner from milliseconds ago)
    // alone; that's action feedback, not bind state.
    clearRenderBoundNotice()

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
      let source = try await Self.readSource(at: url)
      let body = try await renderer.render(source, baseURL: url)
      let composed = try template.composeHTML(
        documentContent: body,
        documentURL: url,
        origin: PreviewSchemeHandler.originURL)
      let html = injectZoomStyle(into: composed.html)
      logLoadingHTML(byteCount: html.count)
      do {
        for try await _ in page.load(html: html, baseURL: composed.baseURL) {}
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
        await find.reapplyIfActive()
      } catch {
        report(failure: error, context: "navigation", lifetime: .renderBound)
      }
    } catch {
      report(failure: error, context: "render", lifetime: .renderBound)
    }
  }

  // MARK: - Logging helpers

  private func logBinding(to url: URL) {
    logger.debug("Binding to document: \(url.path, privacy: .public)")
  }

  private func logLoadingHTML(byteCount: Int) {
    logger.debug("Loading rendered HTML (\(byteCount) bytes)")
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
