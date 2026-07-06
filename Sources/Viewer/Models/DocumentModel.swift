import Foundation
import GalleyCoreKit
import Observation
import OSLog
import SwiftUI
import WebKit
import UserNotifications

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
final class DocumentModel: NavigationModel, ReloadableModel, Identifiable {
  var canReload: Bool { true }

  let page: WebPage
  let zoom: WebPageZoomController

  var isRegular: Bool {
    !documentURL.isFileURL ||
    !documentURL.safe.absoluteString.hasPrefix(
      Bundle.main.bundleURL.safe.absoluteString)
  }
  var canRename: Bool { isRegular && documentURL.isFileURL }
  var canOpenInEditor: Bool { isRegular && documentURL.isFileURL }
  var title: String {
    isRegular ? documentURL.lastPathComponent : String(localized: "Help")
  }
  var toolbarID: String { isRegular ? "viewer.main" : "viewer.help" }

  /// Token for the render-inputs observer (`startTrackingRenderInputs`).
  @ObservationIgnored var reloadObservation: Cancellable?
  @ObservationIgnored var lastRequest: DocumentTarget?

  /// True once this window holds a document (blank windows have no model).
  var hasDocument: Bool { !history.isEmpty }

  @ObservationIgnored private let watcher = DocumentWatcher()
  @ObservationIgnored private let editorBridge = EditorBridge()
  @ObservationIgnored private let linkBridge = LinkBridge()
  @ObservationIgnored private let scrollBridge = ScrollBridge()
  @ObservationIgnored private let backgroundBridge = BackgroundColorBridge()
  @ObservationIgnored let tocBridge = TOCBridge()
  let statsBridge = StatsBridge()

  var currentScrollY: Double { scrollBridge.currentScrollY }
  var currentScroll: Scroll { .location(currentScrollY) }

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
  func pageBackgroundColor(appModel: AppModel) -> Color {
    renderedTemplate(appModel: appModel).backgroundState.color
  }

  /// Per-window template / processor choices. Reference types so
  /// SwiftUI's Observation tracks `selected` for menus that bind to
  /// them. Constructed at init with the per-file persisted IDs (or
  /// `nil` for "use the global selection"); the `persistent` setter
  /// later picks up overrides discovered during state restoration.
  let templates: SceneTemplateChoice
  let processors: SceneProcessorChoice
  /// Per-window color-scheme override. Same `.global(...)` /
  /// `.local(...)` shape as `templates` / `processors`: `.global` means
  /// "follow the AppModel's pick"; `.local` pins a specific scheme.
  /// visionOS-only in practice — macOS scenes adopt the system
  /// appearance directly — but the field is uniform across platforms
  /// so `DocumentModel`'s init signature stays simple.
  let colorSchemes: SceneColorSchemeChoice

  /// The URL the model is currently bound to. Set at construction
  /// from the WindowGroup's URL and updated synchronously at the
  /// start of every `rebindCurrent` (in-window navigation, restore,
  /// rename, reload).
  var documentURL: URL { history.currentURL }

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
  private(set) var renderedTemplateID: Template.ID?

  /// Visited documents in chronological order; `currentIndex` points
  /// at the one currently rendered. Navigation actions move
  /// `currentIndex` and rebind without truncating the stack — so
  /// pressing Forward after Back works. Mutated by the History
  /// extension's `navigate`/`goBack`/`goForward` and by `rename`.
  var history: History

  /// Increments on every `bind(to:)` call. Watcher loops captured by
  /// older bind invocations check this and bail out when superseded.
  @ObservationIgnored private var bindGeneration: Int = 0

  /// Whether the table-of-contents sidebar is visible in the window
  /// hosting this model. Per-document live state — preserved across
  /// in-window link navigation so a child doc inherits the parent's
  /// pick. Cold opens / Replace-current rebinds reset this from the
  /// destination URL's file snapshot instead.
  var showsTOC: Bool = false

  /// One-shot guard for the pre-first-draw sidebar collapse. `true`
  /// means "mount with sidebar open". If sidebar is closed on mount,
  /// the sidebar list top offset will be wrong.
#if os(macOS)
  var mustShowTOC: Bool = true
#else
  // we are handling sidebar differently on other platforms
  var mustShowTOC: Bool = false
#endif

  /// The in-flight TOC scroll, if any. `scrollToHeading` cancels it
  /// before starting a new one, so a later row tap preempts the
  /// current smooth scroll instead of being dropped. Internal
  /// bookkeeping only — `@ObservationIgnored` so it never invalidates
  /// a view.
  @ObservationIgnored var tocScrollTask: Task<Void, Never>? {
    didSet {
      tocBridge.isScrolling = tocScrollTask != nil
    }
  }

  /// Find-text state and JS calls for this window. Owns the query,
  /// options, match counters, and visibility / dismissal flags.
  /// Constructed once `page` is built so it can drive
  /// js find directly. `SearchModel`-conforming so the
  /// `FindBar` view can `@Bindable` it.
  let find: WebPageFindController

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

  private weak var appModel: AppModel?

  let logger = Logger(
    subsystem: bundleIdentifier, category: "DocumentModel")

  convenience init(
    appModel: AppModel,
    url: URL)
  {
    self.init(appModel: appModel, history: History(url: url))
  }

  init(
    appModel: AppModel,
    history: History,
    templatePersistent: Template.PersistentRepresentation? = nil,
    processorPersistent: Processor.PersistentRepresentation? = nil,
    colorSchemePersistent: DocumentColorScheme.PersistentRepresentation? = nil,
    initialScroll: Scroll? = nil,
    initialShowsTOC: Bool = false,
    initialZoom: Double = 1
  ) {
    self.appModel = appModel
    self.history = history
    self.templates = SceneTemplateChoice(
      source: appModel.templates,
      persistent: templatePersistent
    ) { name in
      UNUserNotificationCenter.post(kind: .template, displaced: name)
    }
    self.processors = SceneProcessorChoice(
      source: appModel.processors,
      persistent: processorPersistent
    ) { name in
      UNUserNotificationCenter.post(kind: .processor, displaced: name)
    }
    // Color-scheme catalog is static — same no-op notifier reasoning
    // as `AppModel.colorSchemes`.
    self.colorSchemes = SceneColorSchemeChoice(
      source: appModel.colorSchemes,
      persistent: colorSchemePersistent
    ) { _ in }

    var configuration = WebPage.Configuration()
    configuration.defaultNavigationPreferences.preferredContentMode = .desktop
    let controller = configuration.userContentController
    controller.add(
      // One script handles both cmd-click → editor and plain click →
      // in-window nav, so we don't depend on capture-phase ordering
      // between two listeners — which appears to drop the editor
      // listener after the first navigation in macOS 26 WebPage.
      editorBridge,
      // Debounced scroll listener — feeds `currentScrollY` so
      // DocumentSceneContent can persist the resting position.
      scrollBridge,
      // Heading extraction. Runs once per load, assigns synthetic ids
      // to headings that lack one, and posts the list back. Renderer-
      // agnostic — every Markdown processor we ship outputs `<h1>…<h6>`.
      tocBridge,
      // Word / character / heading counts for the optional status bar.
      // Reads `body.innerText`, so CSS-hidden chrome (template anchors,
      // copy-button glyphs) is excluded from the totals.
      statsBridge,
      // Computed background-color reader. Runs after layout so the
      // host can paint a matching tint behind translucent chrome.
      backgroundBridge,
      linkBridge
    )
    // Find-text controller. The style script runs at document-start
    // so the highlight CSS is in place before any match is wrapped;
    // the controller script runs at document-end so `document.body`
    // exists when js find function is wired up.
    controller.add(WebPageFindController.self)
#if !os(macOS)
    // visionOS pinches the WebView's content like an iOS WKWebView
    // unless the document opts out via viewport meta. Templates we
    // ship don't all declare one, and even when they do the page
    // would still scale on touch. Force a non-scalable viewport so
    // pinch gestures inside the WebView don't fight the app's own
    // zoom action.
    controller.addUserScript(DisablePinchZoomBridge.script)
#endif
    // Custom URL scheme so template-bundled assets (CSS, fonts,
    // images) resolve from disk through the SwiftUI WebView. The
    // provider closure reads the live template selection on every
    // asset request, so a mid-session template switch is reflected
    // in the next `/template/<id>/<file>` lookup without any
    // explicit invalidation.

    let zoom = ZoomController()

    configuration
      .urlSchemeHandlers
      .merge(appModel
        .urlSchemeHandler(templates: templates)
        .mapValues { handler in
          zoom.zoomUrlSchemeHandler(wrapping: handler)
        }, uniquingKeysWith: { _, new in new })

    self.page = WebPage(configuration: configuration)
    self.find = WebPageFindController(page: self.page)
    self.zoom = zoom
    zoom.model = self

    wireBridges(appModel: appModel)

    // Seed scroll/TOC/zoom; render fire-and-forget — no reveal gate.
    showsTOC = initialShowsTOC
    zoom.setZoom(initialZoom)
    startTrackingRenderInputs(appModel: appModel)
    Task { await rebindCurrent(firstScroll: initialScroll ?? .top) }
  }

  /// Attach `[weak self]` callbacks to each bridge. Lifted out of
  /// `init` so the constructor stays under SwiftLint's body-length
  /// budget; called once, immediately after `self` is fully
  /// initialized.
  private func wireBridges(appModel: AppModel) {
    // Browser-style navigation: clicking a markdown link in the
    // rendered preview pushes onto our history and rebinds this same
    // model rather than opening a new document window.
    linkBridge.onMarkdownLink = { [weak self] url in
      Task { await self?.navigate(to: url) }
    }
    // Cmd-click in the preview: route through the model so we read
    // the current `EditorChoice` from appModel on every click.
    editorBridge.onEditorClick = { [weak self, weak appModel] line in
      self?.openInEditor(line: line, appModel: appModel)
    }
    backgroundBridge.onColor = { [weak self, weak appModel] color, templateID in
      self?.onBackgroundColor(color, templateID, appModel: appModel)
    }
  }

  private func onBackgroundColor(
    _ color: Color?, _ templateID: Template.ID?, appModel: AppModel?)
  {
    guard let appModel else { return }
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
    } ?? resolvedTemplate(appModel: appModel)
    renderedTemplateID = painted.persistentID
    // Always persist — `color: nil` records a sentinel so a
    // template that *used to* paint a bg but no longer does (CSS
    // edited) overwrites its stale hex entry. Every other
    // DocumentModel using this template observes the change
    // through their own `pageBackgroundColor` computed property.
    painted.setBackgroundColor(color)
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
  func openInEditor(line: Int? = nil, appModel: AppModel?) {
    guard canOpenInEditor else { return }
    Task { await _openInEditor(line: line, appModel: appModel) }
  }

  private func _openInEditor(line: Int? = nil, appModel: AppModel?) async {
#if os(macOS)
    let url = documentURL
    let resolvedLine: Int?
    if let line {
      resolvedLine = line
    } else {
      resolvedLine = await topmostVisibleSourceLine()
    }
    await appModel?.editors.selected.openFileInEditor(
      url, line: resolvedLine)
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

  private struct TopmostVisibleSourceLineScript: JavaScriptCallable<Int> {
    static let script = Bundle.main.jsScript(name: "topmostVisibleSourceLine")
    var body: String { Self.script }
  }

  private func topmostVisibleSourceLine() async -> Int? {
    do {
      return try await page.callJavaScript(TopmostVisibleSourceLineScript())
    } catch {
      logger.debug("""
        topmostVisibleSourceLine JS failed: \
        \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }

  // MARK: - Public entry points

  /// Initial bind (called from DocumentView's `.task`).
  /// Resets history; this URL becomes the only entry on the stack.
  ///
  /// `target.scrollLine` (set when the open came in via
  /// `galley://…?line=N` from an editor script) becomes a one-shot
  /// `.explicit(.line(_))` intent applied only to the first render of
  /// this bind; absent it, the first render lands at the top.
  /// Subsequent file-watcher reloads preserve current scroll normally.
  func bind(to target: DocumentTarget) async {
    history = History(url: target.documentURL)
    await rebindCurrent(firstScroll: target.scroll ?? .top)
  }

  func reload() async {
    guard let appModel else { return }
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
    let nextTemplateID = resolvedTemplate(appModel: appModel).persistentID
    if nextTemplateID != renderedTemplateID {
      isRenderingNewTemplate = true
    }
    isPageRendered = false
    await renderCurrent(scroll: currentScroll)
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

    let newURL = oldURL.parent / trimmed
    do {
      try oldURL.move(to: newURL)
    } catch {
      report(
        failure: error, context: "rename",
        message: String(
          localized: "Rename failed: \(error.localizedDescription)"),
        lifetime: .ephemeral)
      throw error
    }

    // Patch every history entry that referenced the old URL — Back
    // would otherwise lead to a now-missing path and trip the
    // unreachable-link guard.
    history.replace(oldURL, with: newURL)
    await rebindCurrent(firstScroll: .top)
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
  func rebindCurrent(firstScroll: Scroll) async {
    let url = history.currentURL

    bindGeneration &+= 1
    let myGeneration = bindGeneration
    logBinding(to: url)
    // The WebView's pre-paint canvas is system-white regardless of
    // CSS — clear the rendered flag so DocumentView can mask that
    // gap with the cached page bg until BackgroundColorBridge
    // reports a fresh post-layout color.
    isPageRendered = false
    linkBridge.documentURL = url
    // Drop the old document's TOC entries so the sidebar doesn't
    // flash stale headings during the reload window. The TOCBridge
    // user script repopulates within milliseconds of `page.load`.
    tocBridge.clear()
    statsBridge.clear()

    await renderCurrent(scroll: firstScroll)

    // Only file URLs get a live-reload subscription. Remote
    // documents have no FSEvents source — the user reloads
    // manually via the Reload command.
    guard url.isFileURL else { return }

    let stream = await watcher.subscribe(to: url)
    for await _ in stream {
      if Task.isCancelled || bindGeneration != myGeneration { break }
      // Keep the user's place when the file changes on disk —
      // re-rendering otherwise snaps the WebView back to the top.
      await renderCurrent(scroll: currentScroll)
    }
  }

  private func renderCurrent(scroll targetScroll: Scroll) async {
    guard let appModel else { return }
    // Drop any prior render-bound notice — it described the previous
    // bind and would otherwise sit behind the incoming render until
    // the next failure overwrote it. Leaves an in-flight ephemeral
    // notice (e.g. a broken-link beep banner from milliseconds ago)
    // alone; that's action feedback, not bind state.
    clearRenderBoundNotice()

    let url = documentURL

    // Server-hosted URLs (the AVP Kosmos path): the bridge already
    // returns rendered HTML from `/preview/<path>`. Running that
    // response through `readSource` + the Markdown renderer would
    // feed template HTML to a Markdown parser and bake an empty page.
    // Hand the URL straight to WebPage instead — the Server picked
    // the template, owns livereload (via SSE), and is the renderer.
    do {
      if url.isFileURL {
        let renderer = resolvedRenderer(appModel: appModel)
        let template = resolvedTemplate(appModel: appModel)
        let composed: ComposedPreview
        do {
          let source = try await Self.readSource(at: url)
          let body = try await renderer.render(source, baseURL: url)
          composed = try template.composeHTML(
            documentContent: body,
            documentURL: url,
            origin: PreviewSchemeHandler.originURL)
        } catch {
          report(failure: error, context: "render", lifetime: .renderBound)
          return
        }

        let html = composed.html
        logLoadingHTML(byteCount: html.count)
        for try await _ in page.load(html: html, baseURL: composed.baseURL) {}
      } else {
        for try await _ in page.load(URLRequest(url: url)) {}
      }
    } catch {
      report(failure: error, context: "navigation", lifetime: .renderBound)
      return
    }
    await scroll(to: targetScroll)
    // Old marks died with the previous DOM, but the user's query
    // and the visible find bar are per-window state we want to
    // honor across file-watcher reloads — re-run the search so
    // highlights and counts come back without user action.
    await find.reapplyIfActive()
  }

  // MARK: - Logging helpers

  private func logBinding(to url: URL) {
    logger.debug("Binding to document: \(url.path, privacy: .public)")
  }

  private func logLoadingHTML(byteCount: Int) {
    logger.debug("Loading rendered HTML (\(byteCount) bytes)")
  }
}

extension DocumentTarget {
  var scroll: DocumentModel.Scroll? {
    scrollLine.map { line in .line(line) }
  }
}
