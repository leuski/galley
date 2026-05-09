import AppKit
import GalleyCoreKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The viewer surface for a single document window. Mounted by
/// `ContentView` only when both the WindowGroup binding has resolved
/// to a non-nil URL and the global `AppBoot` has finished processor
/// catalog discovery — so this view always has a concrete URL and a
/// hydrated `AppModel` to work with.
struct DocumentView: View {
  @Binding var fileURL: URL
  let appModel: AppModel
  @Environment(WindowDispatcher.self) private var dispatcher
  @Environment(RecentDocumentsModel.self) private var recents
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
  init(fileURL: Binding<URL>, appModel: AppModel) {
    self._fileURL = fileURL
    self.appModel = appModel
    let url = fileURL.wrappedValue
    let stored = Defaults.shared.perFileStateStore[url]
    self._model = State(wrappedValue: DocumentModel(
      initialURL: url,
      appModel: appModel,
      templatePersistent: stored.templatePersistent,
      processorPersistent: stored.rendererPersistent))
  }

  /// Per-window persisted back/forward stack. SwiftUI's `@SceneStorage`
  /// gives each WindowGroup window its own keyspace, so two windows
  /// each get their own history that survives app relaunch. The
  /// stack is genuinely per-window (a sequence of files visited in
  /// order), so it can't move to `PerFileStateStore` — every other
  /// piece of per-window state has, since `WindowRegistry`'s focus-
  /// existing rule guarantees one window per URL and the per-file
  /// store already carries the same fields.
  @SceneStorage("\(keyPrefix).history") private var historyJSON: String = ""

  var body: some View {
    @Bindable var model = model
    return splitView
      .overlay(alignment: .bottom) {
        if let error = model.lastError {
          Text(error)
            .padding(8)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .padding()
        }
      }
      .background(WindowAccessor(
        onAttach: { window in
          // Re-run registration whenever the resolved NSWindow
          // *changes identity* — but skip a no-op re-attach to the
          // same host. SwiftUI caches scene `@State` for a freshly-
          // closed `WindowGroup<URL>` window and reuses it when the
          // same URL is reopened (the close-a-tab-and-reopen path),
          // which leaves `hostWindow` pointing at the dead AppKit
          // window. A simple `nil` guard here would skip the re-
          // register + tab-merge for the new window — turning the
          // reopened tab into a floating, toolbar-less window.
          guard let window, window !== hostWindow else { return }
          hostWindow = window
          // The window-adoption ceremony (alpha unhide, tab merge,
          // tab "+" hook, registry insert) lives on the dispatcher
          // so it stays unit-testable. See `WindowDispatcher.adopt`.
          dispatcher.adopt(
            window,
            fileURL: fileURL,
            didFirstBind: model.didFirstBind
          ) { newURL in
            replaceDocument(with: newURL)
          }
        },
        onDetach: { window in
          if let window { dispatcher.unregisterWindow(window) }
        }))
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
        model.documentURL.deletingLastPathComponent())
      .navigationTitle(model.documentURL.lastPathComponent)
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
      .navigationDocument(model.documentURL)
  }

  /// The window's main split: TOC sidebar (column-visibility bound to
  /// `model.showsTOC`) and the rendered preview. Hoisted to a
  /// `NavigationSplitView` so AppKit's tab bar spans only the detail
  /// column — a sidebar nested inside an `HStack` would render with
  /// the tab bar bisecting it.
  @ViewBuilder
  private var splitView: some View {
    NavigationSplitView(columnVisibility: Binding(
      get: { model.showsTOC ? .all : .detailOnly },
      set: { newValue in
        let next = newValue != .detailOnly
        withAnimationAsNeeded(reduceMotion) { model.showsTOC = next }
      }
    )) {
      TOCSidebar(model: model)
        .listStyle(.sidebar)
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
          if model.isFindVisible {
            FindBar(model: model)
              .transition(.move(edge: .top).combined(with: .opacity))
          }
        }
        .toolbar(id: "viewer.main") { toolbarContent(appModel: appModel) }
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
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    // `model.pageBackgroundColor` already resolves through the
    // template state → last-seen → system-bg fallback chain, so
    // it's always a real color; no second `??` needed here.
    .background(model.pageBackgroundColor)
    .containerBackground(model.pageBackgroundColor, for: .window)
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
      ? .userSystem
      : (model.pageBackgroundColor.isLuminanceDark ? .dark : .light))
  }

  /// Called whenever the model's bind state changes — first render,
  /// in-window link navigation, restore, rename. Persists the
  /// back/forward stack, updates the dispatcher's registry, and
  /// reveals the window once the first bind completes. Idempotent;
  /// safe to call from multiple `.onChange` observers.
  private func handleDocumentBound() {
    saveHistory()
    if let window = hostWindow {
      dispatcher.updateCurrentURL(window, model.documentURL)
    }
    if model.didFirstBind {
      hostWindow?.alphaValue = 1
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
        if fileURL != newURL { fileURL = newURL }
      } catch {
        NSSound.beep()
      }
    }
  }

  /// Swap this window's bound document for `newURL` in place. Used by
  /// the `replaceCurrent` open behavior. Updates the WindowGroup
  /// binding so state restoration follows, and rebinds the model so
  /// history/watcher restart on the new URL.
  private func replaceDocument(with newURL: URL) {
    recents.record(newURL)
    if fileURL != newURL { fileURL = newURL }
    let line = dispatcher.consumePendingScrollLine(for: newURL)
    // Replace-current is a fresh-doc switch, not a parent→child
    // navigation, so re-seed the TOC sidebar from the destination's
    // own per-file pref rather than inheriting the previous doc's
    // live setting.
    let initialShowsTOC = Defaults.shared.perFileStateStore[newURL]
      .showsTOC ?? false
    Task {
      // Same URL re-dispatch (e.g. BBEdit's preview script firing
      // again on a file already showing): just scroll, don't tear
      // down history. A fresh URL takes the full bind path.
      if model.documentURL == newURL, let line {
        await model.scrollToSourceLine(line)
      } else {
        await model.bind(
          to: newURL,
          scrollToLine: line,
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
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: model.didFirstBind,
      didRestore: didRestore,
      historyJSON: historyJSON,
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
      recents.record(model.documentURL)

    case .initialBind(let url, let scrollY, let showsTOC):
      recents.record(url)
      let line = dispatcher.consumePendingScrollLine(for: url)
      await model.bind(
        to: url,
        scrollToLine: line,
        initialScrollY: scrollY,
        initialShowsTOC: showsTOC)
    }
  }

  private func saveHistory() {
    historyJSON = model.historySnapshot?.encodedAsJSON() ?? ""
  }

  @ToolbarContentBuilder
  private func toolbarContent(
    appModel: AppModel
  ) -> some CustomizableToolbarContent {
    navigationToolbarItems
    //    ToolbarSpacer(.flexible, placement: .automatic)
    mainToolbarItems(appModel: appModel)
    zoomToolbarItems
    //    ToolbarSpacer(.fixed, placement: .automatic)
  }

  @ToolbarContentBuilder
  private var navigationToolbarItems: some CustomizableToolbarContent {
    // Replacement for SwiftUI's auto-injected NavigationSplitView
    // toggle — see the `.toolbar(removing: .sidebarToggle)` comment in
    // `body`. `.customizationBehavior(.disabled)` keeps this item out
    // of the customization config so it can't ever round-trip through
    // defaults and trigger the duplicate-identifier crash.
    //    ToolbarItem(id: "toggleTOC", placement: .navigation) {
    //      Action.toggleTOC.toolbarItem(model: model)
    //    }
    //    .customizationBehavior(.disabled)
    //
    ToolbarItem(id: "back", placement: .navigation) {
      Action.back.toolbarItem(model: model)
    }
    .customizationBehavior(.default)

    ToolbarItem(id: "forward", placement: .navigation) {
      Action.forward.toolbarItem(model: model)
    }
    .customizationBehavior(.default)
  }

  @ToolbarContentBuilder
  private func mainToolbarItems(
    appModel: AppModel
  ) -> some CustomizableToolbarContent {
    ToolbarItem(id: "renderer", placement: .primaryAction) {
      RendererToolbarPicker(appModel: appModel, docModel: model)
    }
    .customizationBehavior(.default)

    ToolbarItem(id: "template", placement: .primaryAction) {
      TemplateToolbarPicker(appModel: appModel, docModel: model)
    }
    .customizationBehavior(.default)

    ToolbarItem(id: "reload", placement: .primaryAction) {
      Action.reload.toolbarItem(model: model)
    }
    .customizationBehavior(.default)

    ToolbarItem(id: "find", placement: .primaryAction) {
      Action.find.toolbarItem(model: model)
    }
    .customizationBehavior(.default)
  }

  @ToolbarContentBuilder
  private var zoomToolbarItems: some CustomizableToolbarContent {
    ToolbarItem(id: "zoomOut", placement: .primaryAction) {
      Action.zoomOut.toolbarItem(model: model)
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "zoomReset", placement: .primaryAction) {
      Action.resetZoom.toolbarItem(model: model)
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "zoomIn", placement: .primaryAction) {
      Action.zoomIn.toolbarItem(model: model)
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
      title: "Processor",
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
      title: "Template",
      appModel: appModel,
      documentModel: docModel)
    .scaleEffect(toolbarMenuIconScale, anchor: .center)
    .help("Template")
  }
}
