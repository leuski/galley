#if os(macOS)
import AppKit
import GalleyCoreKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import KosmosAppKit

private let log = Logger(
  subsystem: bundleIdentifier, category: "DocumentView")

/// The viewer surface for a single document window. Mounted by
/// `ContentView` only when both the WindowGroup binding has resolved
/// to a non-nil URL and the global `AppBoot` has finished processor
/// catalog discovery — so this view always has a concrete URL and a
/// hydrated `AppModel` to work with.
struct DocumentView: View {
  @Binding var target: DocumentTarget
  let appModel: AppModel
  @Environment(RecentDocumentsModel.self) private var recents
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var model: DocumentModel
  @State private var didRestore = false
  @State private var hostWindow: NSWindow?

  /// Transient text-field value for the rename alert. Seeded from
  /// `model.documentURL.lastPathComponent` whenever
  /// `model.isRenameRequested` flips true (see the `.onChange` in
  /// `body`). Lives on the view because it has no meaning outside
  /// the alert's lifetime.
  @State private var renameInput = ""

  /// Non-nil while the SwiftUI "Couldn't export PDF" alert is up.
  /// Set by the export flow on failure; cleared when the alert is
  /// dismissed.
  @State private var exportPDFError: String?

  /// Constructs the model with the WindowGroup's bound URL plus the
  /// per-file persisted choice IDs so `documentURL`, `templates`, and
  /// `processors` are all set synchronously at view-identity creation.
  /// `didFirstBind` is still false until `.task` triggers the first
  /// render — that's the signal `WindowAccessor` and `ChangeHandlers`
  /// use for window-reveal alpha and history persistence.
  ///
  /// State-restored windows that come back to a different URL than
  /// the WindowGroup's binding will have their persistent IDs updated
  /// in `launchTask` once the snapshot is decoded.
  init(
    target: Binding<DocumentTarget>,
    appModel: AppModel,
    kind: DocumentModel.Kind = .document
  ) {
    self._target = target
    self.appModel = appModel
    let url = target.wrappedValue.documentURL
    let stored = Defaults.shared.perFileStateStore[url]
    self._model = State(wrappedValue: DocumentModel(
      initialURL: url,
      appModel: appModel,
      templatePersistent: stored.templatePersistent,
      processorPersistent: stored.rendererPersistent,
      kind: kind))
  }

  /// Per-window persisted back/forward stack. SwiftUI's `@SceneStorage`
  /// gives each WindowGroup window its own keyspace, so two windows
  /// each get their own history that survives app relaunch. The
  /// stack is genuinely per-window (a sequence of files visited in
  /// order), so it can't move to `PerFileStateStore` — every other
  /// piece of per-window state has, since the `preferring:` dedup
  /// keeps one window per URL and the per-file store already carries
  /// the same fields.
  @SceneStorage("history")
  private var history: SceneStoragePayload<HistorySnapshot>?

  var body: some View {
    @Bindable var model = model
    return splitView
      .overlay(alignment: .bottom) {
        if let notice = model.notice {
          NoticeBanner(message: notice.message) {
            model.dismissNotice()
          }
          .padding()
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(reduceMotion ? nil : .default, value: model.notice)
      .windowAccessor { window in
        // Reveal whenever the resolved NSWindow changes identity —
        // skip a no-op re-attach to the same host. SwiftUI caches
        // scene `@State` for a freshly-closed `WindowGroup`
        // window and reuses it when the same target is reopened; a plain
        // `nil` guard would leave the reopened tab toolbar-less.
        guard let window, window !== hostWindow else { return }
        hostWindow = window
        window.alphaValue = model.didFirstBind ? 1 : 0
        // Tabs are born into the key group at creation (born-as-tab,
        // no post-hoc `addTabbedWindow` flash — WindowProbe FINDINGS
        // §8). We only still patch the AppKit tab-bar "+" so a user
        // "+" click runs the Open panel + opens a tab. Help skips it.
        if model.kind == .document {
          NewTabAction.install(on: window)
        }
      }
      // A document window prefers its own URL so a repeat-open routes
      // back here (dedup) instead of duplicating; the token list
      // tracks `model.documentURL` reactively, covering in-window
      // navigation. Help windows opt out — they never receive URLs.
      .handlesInboundURLs(
        enabled: model.kind == .document,
        preferring: model.documentURL.galleyPreferringTokens,
        onDocument: handleInbound)
      .focusedSceneValue(\.documentModel, model)
      .alert(
        "Rename Document",
        isPresented: $model.isRenameRequested
      ) {
        TextField(
          model.documentURL.lastPathComponent, text: $renameInput)
        Button("Rename") { performRename() }
        Button("Cancel", role: .cancel) { }
      } message: {
        Text("Enter a new file name for this document.")
      }
      .onChange(of: model.isRenameRequested) { _, new in
        if new { renameInput = model.documentURL.lastPathComponent }
      }
      .alert(
        "Couldn’t export PDF",
        isPresented: exportPDFErrorPresented,
        presenting: exportPDFError
      ) { _ in
        Button("OK") { exportPDFError = nil }
      } message: { message in
        Text(message)
      }
      .fileExporter(
        isPresented: $model.isExportingPDF,
        item: model.pdfExport,
        contentTypes: [.pdf],
        defaultFilename: model.documentURL
          .deletingPathExtension().lastPathComponent
      ) { result in
        if case .failure(let error) = result {
          exportPDFError = error.localizedDescription
        }
      }
      .fileDialogDefaultDirectory(
        model.documentURL.parent)
    // No `id:` — `replaceDocument` drives in-window URL changes
    // directly through `model.bind(to:)`, so re-firing on every
    // `fileURL` write would be wasted work that the early-return
    // in `launchTask` already short-circuits.
      .task { await launchTask() }
      .modifier(ChangeHandlers(
        model: model,
        appModel: appModel,
        onBindStateChanged: handleDocumentBound,
        onTemplatePersistent: mirrorPerFileTemplate,
        onRendererPersistent: mirrorPerFileRenderer,
        onZoom: mirrorPerFileZoom,
        onScrollY: mirrorPerFileScrollY,
        onShowsTOC: mirrorPerFileShowsTOC,
        reload: reloadModel))
      .navigationDocument(model.documentURL, when: model.kind == .document)
      .navigationTitle(
        model.kind == .help
          ? Text("Help")
          : Text(model.documentURL.lastPathComponent))
      .navigationSubtitle(model.page.title)
  }

  /// The window's main split: TOC sidebar (column-visibility bound to
  /// `model.showsTOC`) and the rendered preview. Hoisted to a
  /// `NavigationSplitView` so AppKit's tab bar spans only the detail
  /// column — a sidebar nested inside an `HStack` would render with
  /// the tab bar bisecting it.
  @ViewBuilder
  private var splitView: some View {
    NavigationSplitView(
      columnVisibility: model.tocColumnVisibility(reduceMotion: reduceMotion))
    {
      TOCSidebar(model: model)
        .navigationSplitViewColumnWidth(
          min: 180, ideal: 220, max: 320)
      // SwiftUI auto-injects a sidebar toggle item into NavigationSplitView's
      // toolbar under the identifier `com.apple.SwiftUI.navigationSplitView.
      // toggleSidebar`. Combined with `.toolbar(id: "viewer.main")`'s
      // customization persistence, that identifier ends up both auto-injected
      // and restored from defaults on the next launch — NSToolbar then
      // throws because the same identifier appears twice. Suppress the
      // auto-injected one and provide our own non-customizable toggle in
      // `navigationToolbarItems` instead.
    } detail: {
      WebView(model.page)
        .frame(minWidth: webViewMinWidth)
        // Collapse the TOC sidebar just before the very first paint
        // of this split view if the user wanted it closed. `showsTOC`
        // starts `true` so NavigationSplitView is born with a sidebar
        // and AppKit wires the column as `.behavior = .sidebar` (so
        // it extends up under the tab bar). `savedShowsTOC` holds the
        // user's actual preference; we apply it inside `viewWillDraw`
        // — same runloop turn as the first paint, so the visible
        // state never includes the open-sidebar frame. One-shot via
        // the `savedShowsTOC` flag flip.
        .willPresent {
          if !model.savedShowsTOC {
            model.savedShowsTOC = true
            model.showsTOC = false
          }
        }
        // The WebView's pre-paint canvas paints system-white during
        // the gap between mount and the first HTML layout — visible
        // as a white flash on tab open / reload regardless of CSS.
        // Cover that gap with the resolved page bg (which falls
        // back through last-seen → system bg) until `isPageRendered`
        // flips true via the BackgroundColorBridge post-layout fire.
        .overlay {
          if !model.isPageRendered {
            model.pageBackgroundColor.allowsHitTesting(false)
          }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
          if model.find.isVisible {
            FindBar(model: model.find)
              .transition(.move(edge: .top).combined(with: .opacity))
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if Defaults.shared.showsStatusBar {
            StatusBar(
              stats: model.stats,
              wordsPerMinute: Defaults.shared.readingWordsPerMinute)
              .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .toolbar(id: model.kind == .document ? "viewer.main" : "viewer.help") {
          toolbarContent(appModel: appModel)
        }
    }
    .navigationSplitViewStyle(.balanced)
    // Paint the page's own background color into the window's
    // container background so the translucent toolbar / sidebar
    // chrome samples it as the surface behind their glass material.
    // `.containerBackground(_:for: .window)` — unlike `.background`
    // — paints behind the entire window container, which is what
    // chrome reads through. `nil` while loading or when the page
    // declared no opaque bg; we then paint nothing and fall back to
    // the system default (glass over wallpaper).
    .toolbarBackgroundVisibility(
      Defaults.shared.tintWindowWithPageBackground ? .hidden : .visible,
      for: .windowToolbar)
    // `model.pageBackgroundColor` already resolves through the
    // template state → last-seen → system-bg fallback chain, so
    // it's always a real color; no second `??` needed here.
    .background(
      Defaults.shared.tintWindowWithPageBackground
      ? model.pageBackgroundColor : .userSystemWindowBackground)
    .containerBackground(
      Defaults.shared.tintWindowWithPageBackground
      ? model.pageBackgroundColor : .userSystemWindowBackground, for: .window)
    // Flip the view's color scheme so AppKit-rendered chrome text
    // (window title, toolbar labels) inverts when the page bg is
    // dark — otherwise the system black title disappears against a
    // black body. While re-rendering after a template change,
    // pin the scheme to the user's system pref instead so WebKit's
    // `prefers-color-scheme` media queries on the new template pick
    // the user's preferred variant — not whichever variant was
    // current under the previous template's bg-luminance scheme.
    .preferredColorScheme(
      model.isRenderingNewTemplate
      || !Defaults.shared.tintWindowWithPageBackground
      ? .userSystem
      : (model.pageBackgroundColor.isLuminanceDark ? .dark : .light))
  }

  /// Called whenever the model's bind state changes — first render,
  /// in-window link navigation, restore, rename. Persists the
  /// back/forward stack and reveals the window once the first bind
  /// completes. Idempotent; safe to call from multiple `.onChange`
  /// observers.
  private func handleDocumentBound() {
    saveHistory()
    // The window's `preferring:` dedup tokens track `model.documentURL`
    // reactively (see `handlesInboundURLs` in `body`), so in-window
    // navigation re-advertises this window's claim with no extra work.
    if model.didFirstBind {
      hostWindow?.alphaValue = 1
    }
  }

  /// Apply an inbound document URL that SwiftUI routed to this window.
  /// Re-open of the doc this window already shows → just scroll +
  /// focus (dedup). Otherwise honor the user's open-behavior:
  /// `replaceCurrent` rebinds this window in place; `newWindow` /
  /// `newTab` spawn a fresh window (born standalone or born-as-tab via
  /// `allowsAutomaticWindowTabbing` — WindowProbe FINDINGS §9).
  private func handleInbound(_ info: DocumentTarget) {
    if model.documentURL.standardizedFileURL == info
      .documentURL.standardizedFileURL
    {
      if let line = info.scrollLine {
        Task { await model.scrollToSourceLine(line) }
      }
      NSApp.activate(ignoringOtherApps: true)
      hostWindow?.makeKeyAndOrderFront(nil)
      return
    }
    recents.record(info.documentURL)
    switch Defaults.shared.openBehavior {
    case .replaceCurrent:
      replaceDocument(info)
    case .newTab, .newWindow:
      NSWindow.allowsAutomaticWindowTabbing =
        Defaults.shared.openBehavior == .newTab
      openWindow(id: DocumentScene.id, value: info)
    }
  }

  private func reloadModel() {
    Task { await model.reload() }
  }

  /// Persist changes to `PerFileStateStore` keyed by the model's
  /// current document URL. Each writer nils the field for that
  /// field's default value so the dictionary doesn't accumulate dead
  /// entries.
  private func mirrorPerFileZoom(_ value: Double) {
    Defaults.shared.perFileStateStore[model.documentURL]
      .pageZoom = value == 1.0 ? nil : value
  }

  private func mirrorPerFileScrollY(_ value: Double) {
    Defaults.shared.perFileStateStore[model.documentURL]
      .scrollY = value == 0 ? nil : value
  }

  private func mirrorPerFileTemplate(_ value: String?) {
    Defaults.shared.perFileStateStore[model.documentURL]
      .templatePersistent = value
  }

  private func mirrorPerFileRenderer(_ value: String?) {
    Defaults.shared.perFileStateStore[model.documentURL]
      .rendererPersistent = value
  }

  private func mirrorPerFileShowsTOC(_ value: Bool) {
    Defaults.shared.perFileStateStore[model.documentURL]
      .showsTOC = value ? true : nil
  }

  /// Bridges the optional error string to the boolean the
  /// `.alert(... isPresented:)` modifier expects: clearing the error
  /// dismisses the alert and vice versa.
  private var exportPDFErrorPresented: Binding<Bool> {
    Binding(
      get: { exportPDFError != nil },
      set: { if !$0 { exportPDFError = nil } })
  }

  /// Run the rename triggered by the SwiftUI alert's "Rename" button.
  /// Trims whitespace, no-ops on empty / unchanged input, beeps on
  /// failure (matches the prior NSAlert flow), and on success records
  /// the renamed URL with Open Recent and follows the WindowGroup
  /// binding to the new path.
  private func performRename() {
    let trimmed = renameInput
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let currentURL = model.documentURL
    guard !trimmed.isEmpty, trimmed != currentURL.lastPathComponent
    else { return }
    Task { @MainActor in
      do {
        let newURL = try await model.renameCurrentDocument(toName: trimmed)
        recents.record(newURL)
        if target.documentURL != newURL { target = .init(url: newURL) }
      } catch {
        // `renameCurrentDocument` already posted a notice banner via
        // `report(failure:)`. Beep matches the prior NSAlert UX; log
        // the underlying error so support reports retain context.
        log.error("""
          Rename failed for \(model.documentURL.path, privacy: .private): \
          \(error.localizedDescription, privacy: .public)
          """)
        NSSound.beep()
      }
    }
  }

  /// Swap this window's bound document for `newURL` in place. Used by
  /// the `replaceCurrent` open behavior. Updates the WindowGroup
  /// binding so state restoration follows, and rebinds the model so
  /// history/watcher restart on the new URL.
  private func replaceDocument(_ target: DocumentTarget) {
    recents.record(target.documentURL)
    if self.target != target { self.target = target }
    let line = target.scrollLine
    // Replace-current is a fresh-doc switch, not a parent→child
    // navigation, so re-seed the TOC sidebar from the destination's
    // own per-file pref rather than inheriting the previous doc's
    // live setting.
    let initialShowsTOC = Defaults.shared.perFileStateStore[target.documentURL]
      .showsTOC ?? false
    Task {
      // Same URL re-dispatch (e.g. BBEdit's preview script firing
      // again on a file already showing): just scroll, don't tear
      // down history. A fresh URL takes the full bind path.
      if model.documentURL == target.documentURL, let line {
        await model.scrollToSourceLine(line)
      } else {
        await model.bind(
          to: target,
          initialShowsTOC: initialShowsTOC)
      }
    }
  }

  /// Drives initial bind for a document window. Mounted only after
  /// `boot.model` is non-nil, so by the time this fires processor
  /// discovery has completed and the persisted pick has been decoded
  /// against the live catalog.
  ///
  /// The pure decision lives in `BindPlan.decide(...)`; this method
  /// is its interpreter — applies zoom / choice overrides, then
  /// dispatches to `model.restore` or `model.bind` (or returns when
  /// the model is already bound).
  private func launchTask() async {
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      hostWindow?.makeKeyAndOrderFront(nil)
      hostWindow?.tabGroup?.selectedWindow = hostWindow
    }

    let plan = BindPlan.decide(
      target: target,
      didFirstBind: model.didFirstBind,
      didRestore: didRestore,
      history: try? history?.value,
      perFileState: { Defaults.shared.perFileStateStore[$0] })

    // `setZoom` only updates a JS rule on the live page; the next
    // render reads `model.pageZoom` to inject the matching CSS so
    // the first frame comes up at the right size.
    model.setZoom(plan.zoom)

    if plan.applyChoiceOverrides {
      model.templates.persistent = plan.templateOverride
      model.processors.persistent = plan.rendererOverride
    }

    switch plan.action {
    case .alreadyBound:
      return

    case .restore(let snapshot, let scrollY, let showsTOC):
      didRestore = true
      await model.restore(
        snapshot: snapshot,
        initialScrollY: scrollY,
        initialShowsTOC: showsTOC)

    case .initialBind(let target, let scrollY, let showsTOC):
      recents.record(target.documentURL)
      await model.bind(
        to: target,
        initialScrollY: scrollY,
        initialShowsTOC: showsTOC)
    }
  }

  private func saveHistory() {
    history = model.historySnapshot.flatMap { try? .init($0) }
  }

  @ToolbarContentBuilder
  private func toolbarContent(
    appModel: AppModel
  ) -> some CustomizableToolbarContent {
    navigationToolbarItems
    //    ToolbarSpacer(.flexible, placement: .automatic)
    if model.kind == .document {
      mainToolbarItems(appModel: appModel)
    }
    zoomToolbarItems
    //    ToolbarSpacer(.fixed, placement: .automatic)
  }

  @ToolbarContentBuilder
  private var navigationToolbarItems: some CustomizableToolbarContent {
    ToolbarItem(id: "backForward", placement: .navigation) {
      Label {
        Text("Back/Forward")
      } icon: {
        ControlGroup {
          Action.back(model).toolbarItem()
          Action.forward(model).toolbarItem()
        }
        .controlGroupStyle(.navigation)
      }
    }
    .defaultCustomization(.hidden)
  }

  @ToolbarContentBuilder
  private func mainToolbarItems(
    appModel: AppModel
  ) -> some CustomizableToolbarContent {
    ToolbarItem(id: "renderer", placement: .confirmationAction) {
      RendererToolbarPicker(appModel: appModel, docModel: model)
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "template", placement: .confirmationAction) {
      TemplateToolbarPicker(appModel: appModel, docModel: model)
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "reload", placement: .confirmationAction) {
      Action.reload(model).toolbarItem()
    }
    .defaultCustomization(.hidden)
  }

  @ToolbarContentBuilder
  private var zoomToolbarItems: some CustomizableToolbarContent {
    ToolbarItem(id: "zoomOut", placement: .confirmationAction) {
      Action.zoomOut(model).toolbarItem()
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "zoomReset", placement: .confirmationAction) {
      Action.resetZoom(model).toolbarItem()
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "zoomIn", placement: .confirmationAction) {
      Action.zoomIn(model).toolbarItem()
    }
    .defaultCustomization(.hidden)
  }

  private var zoomLabel: String {
    let percent = Int((model.pageZoom * 100).rounded())
    return "\(percent)%"
  }
}

/// Bundles every `.onChange` handler `DocumentView` needs. Keeps the
/// view body short and isolates the mirroring logic between model
/// state and the enclosing scene's `@SceneStorage` slots.
private struct ChangeHandlers: ViewModifier {
  let model: DocumentModel
  let appModel: AppModel
  let onBindStateChanged: () -> Void
  let onTemplatePersistent: (String?) -> Void
  let onRendererPersistent: (String?) -> Void
  let onZoom: (Double) -> Void
  let onScrollY: (Double) -> Void
  let onShowsTOC: (Bool) -> Void
  let reload: () -> Void

  func body(content: Content) -> some View {
    content
    // Two signals feed the same handler. `documentURL` covers
    // every URL change after the first bind (in-window navigation,
    // restore to a different URL, rename). `didFirstBind` covers
    // the initial bind — necessary because `bind(to: initialURL)`
    // assigns the same value `init(initialURL:)` already wrote, so
    // `.onChange(of: documentURL)` doesn't fire on first run.
      .onChange(of: model.documentURL) { _, _ in onBindStateChanged() }
      .onChange(of: model.didFirstBind) { _, _ in onBindStateChanged() }
      .onChange(of: appModel.processors.selected) { reload() }
      .onChange(of: appModel.templates.selected) { reload() }
      .onChange(of: Defaults.shared.enablePerDocumentOverrides) { reload() }
      .onChange(of: model.templates.persistent) { _, new in
        onTemplatePersistent(new)
        reload()
      }
      .onChange(of: model.processors.persistent) { _, new in
        onRendererPersistent(new)
        reload()
      }
      .onChange(of: model.pageZoom) { _, new in onZoom(new) }
      .onChange(of: model.currentScrollY) { _, new in onScrollY(new) }
      .onChange(of: model.showsTOC) { _, new in onShowsTOC(new) }
  }
}

/// Brings a toolbar `Menu` icon down to the visual size of sibling
/// toolbar buttons. SwiftUI hosts toolbar menus as `NSMenuToolbarItem`
/// at AppKit's larger metric, and font / imageScale / controlSize all
/// get dropped at the bridge — only `.scaleEffect` survives because it
/// runs at the SwiftUI compositor before AppKit sees the rendered
/// layer. Hit-testing keeps the original frame, which is fine.
/// This is only needed (0.8) for unifiedCompact toolbar style. .unified
/// style works correctly with scale set to 1.
private let toolbarMenuIconScale: CGFloat = 1.0

private struct RendererToolbarPicker: View {
  @Bindable var appModel: AppModel
  @Bindable var docModel: DocumentModel

  var body: some View {
    processorMenu(
      appModel: appModel,
      documentModel: docModel)
    .scaleEffect(toolbarMenuIconScale, anchor: .center)
    .help("Markdown processor")
  }
}

private struct TemplateToolbarPicker: View {
  @Bindable var appModel: AppModel
  @Bindable var docModel: DocumentModel

  var body: some View {
    templateMenu(
      appModel: appModel,
      documentModel: docModel)
    .scaleEffect(toolbarMenuIconScale, anchor: .center)
    .help("Template")
  }
}

private extension View {
  /// Gates `.navigationDocument(_:)` on a condition. The Help window's
  /// `DocumentView` opts out so AppKit doesn't attach a proxy icon or
  /// the title-bar document menu (rename / move / version) to what is
  /// really a read-only resource inside the app bundle.
  @ViewBuilder
  func navigationDocument(_ url: URL, when condition: Bool) -> some View {
    if condition { navigationDocument(url) } else { self }
  }
}

/// Bottom-overlay banner for `DocumentModel.notice`. Owns no state —
/// the close button calls `onDismiss` so the model can cancel any
/// pending auto-clear timer alongside clearing the notice.
private struct NoticeBanner: View {
  let message: String
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Text(message)
        .textSelection(.enabled)
      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(8)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
  }
}
#endif
