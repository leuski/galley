import AppKit
import GalleyCoreKit
import SwiftUI
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
  @State private var model: DocumentModel
  @State private var didRestore = false
  @State private var hostWindow: NSWindow?

  /// Constructs the model with the WindowGroup's bound URL so
  /// `documentURL` is set synchronously at view-identity creation.
  /// `didFirstBind` is still false until `.task` triggers the first
  /// render — that's the signal `WindowAccessor` and `ChangeHandlers`
  /// use for window-reveal alpha and history persistence.
  init(fileURL: Binding<URL>, appModel: AppModel) {
    self._fileURL = fileURL
    self.appModel = appModel
    self._model = State(
      wrappedValue: DocumentModel(initialURL: fileURL.wrappedValue))
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
    splitView
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
          if hostWindow == nil {
            hostWindow = window
            // Every window opens hidden until content is bound. State
            // restoration applies the URL ~half a second after a view
            // mounts, and a fresh placeholder sits empty until the
            // open panel returns. We can't predict the order of this
            // resolve vs. .task firing — if a previous fire already
            // bound content (e.g. openWindow(value:) → immediate
            // bind), unhide right away.
            window?.alphaValue = model.didFirstBind ? 1 : 0
          }
          if let window {
            // Merge into the frontmost window's tab group if this open
            // came in under the `newTab` behavior. Has to happen as
            // soon as the new window exists so the user never sees
            // it as a separate floating window first.
            if let host = dispatcher.consumePendingTabHost(),
               host !== window
            {
              host.addTabbedWindow(window, ordered: .above)
            }
            // Hook the AppKit tab bar's "+" button — see
            // `NewTabAction.install(on:)`. The "+" sends
            // `newWindowForTab:` into a `WindowGroup<URL>` that has
            // no default value, and SwiftUI's default tears down the
            // current window instead of spawning a new tab. We
            // intercept that selector and dispatch to the static
            // `handler` (configured by `ViewerApp`) so "+" runs the
            // Open panel and merges picks as tabs onto the source
            // window — the Safari/Preview pattern.
            NewTabAction.install(on: window)
            dispatcher.registerWindow(
              window,
              initialURL: fileURL
            ) { newURL in
              replaceDocument(with: newURL)
            }
          }
        },
        onDetach: { window in
          if let window { dispatcher.unregisterWindow(window) }
        }))
      .toolbar(id: "viewer.main") { toolbarContent(appModel: appModel) }
      .modifier(SceneValuesModifier(
        model: model,
        renameContext: RenameContext(
          url: model.documentURL,
          apply: { newURL in
            recents.record(newURL)
            if fileURL != newURL { fileURL = newURL }
          })))
      .navigationTitle(model.documentURL.lastPathComponent)
      .task(id: fileURL) { await launchTask() }
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
      set: { model.showsTOC = ($0 != .detailOnly) }
    )) {
      TOCSidebar(model: model)
        .navigationSplitViewColumnWidth(
          min: 180, ideal: 220, max: 320)
    } detail: {
      WebView(model.page)
    }
    .navigationSplitViewStyle(.balanced)
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

  /// Persist a change to `PerFileStateStore` keyed by the model's
  /// current document URL. Each writer nils the field for the field's
  /// default value so the dictionary doesn't accumulate dead entries.
  private func mirrorPerFileZoom(_ value: Double) {
    writePerFileState { $0.pageZoom = value == 1.0 ? nil : value }
  }

  private func mirrorPerFileScrollY(_ value: Double) {
    writePerFileState { $0.scrollY = value == 0 ? nil : value }
  }

  private func mirrorPerFileTemplate(_ value: String?) {
    writePerFileState { $0.templatePersistent = value }
  }

  private func mirrorPerFileRenderer(_ value: String?) {
    writePerFileState { $0.rendererPersistent = value }
  }

  private func mirrorPerFileShowsTOC(_ value: Bool) {
    writePerFileState { $0.showsTOC = value ? true : nil }
  }

  private func writePerFileState(
    _ mutation: (inout PerFileState) -> Void
  ) {
    mutation(&Defaults.shared.perFileStateStore[model.documentURL])
  }

  /// Read the `PerFileState` slot for `url`, returning an empty
  /// record when there is no stored entry yet.
  private func perFileState(for url: URL) -> PerFileState {
    Defaults.shared.perFileStateStore[url]
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
    let stored = perFileState(for: newURL)
    let initialShowsTOC = stored.showsTOC ?? false
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
  private func launchTask() async {
    // The URL we're about to display: the snapshot's current entry
    // for a state-restored window, or the WindowGroup-bound URL for
    // a fresh open. `PerFileStateStore` is the single source of
    // truth for everything keyed by file path (zoom / scroll /
    // overrides / TOC) — read once, hand pieces off to the model.
    let snapshot = !didRestore ? decodeHistory(historyJSON) : nil
    let initialURL = snapshot?.currentURL ?? fileURL
    let stored = perFileState(for: initialURL)

    // `setZoom` only updates a JS rule on the live page; the next
    // render reads `model.pageZoom` to inject the matching CSS so
    // the first frame comes up at the right size.
    model.setZoom(stored.pageZoom ?? 1.0)
    model.bindSettings(
      appModel,
      templatePersistent: stored.templatePersistent,
      processorPersistent: stored.rendererPersistent)

    // SwiftUI fires `.task(id:)` more than once even when the id
    // is stable (the modifier is recreated on body re-eval). Once
    // the first rebind has run, every subsequent fire is a no-op.
    if model.didFirstBind { return }

    // Restore a saved session (back/forward stack) for this scene.
    if !didRestore, let snapshot {
      didRestore = true
      await model.restore(
        snapshot: snapshot,
        initialScrollY: stored.scrollY,
        initialShowsTOC: stored.showsTOC ?? false)
      recents.record(model.documentURL)
      return
    }

    // Initial bind for a freshly-opened URL.
    recents.record(fileURL)
    let line = dispatcher.consumePendingScrollLine(for: fileURL)
    await model.bind(
      to: fileURL,
      scrollToLine: line,
      initialScrollY: stored.scrollY,
      initialShowsTOC: stored.showsTOC ?? false)
  }

  private func saveHistory() {
    guard let snapshot = model.historySnapshot else {
      historyJSON = ""
      return
    }
    if let data = try? JSONEncoder().encode(snapshot),
       let text = String(data: data, encoding: .utf8)
    {
      historyJSON = text
    }
  }

  private func decodeHistory(_ text: String) -> HistorySnapshot? {
    guard !text.isEmpty,
          let data = text.data(using: .utf8),
          let snapshot = try? JSONDecoder().decode(
            HistorySnapshot.self, from: data),
          !snapshot.urls.isEmpty
    else { return nil }
    return snapshot
  }

  @ToolbarContentBuilder
  private func toolbarContent(
    appModel: AppModel
  ) -> some CustomizableToolbarContent {
    navigationToolbarItems
    ToolbarSpacer(.flexible, placement: .automatic)
    mainToolbarItems(appModel: appModel)
    zoomToolbarItems
    ToolbarSpacer(.fixed, placement: .automatic)
  }

  @ToolbarContentBuilder
  private var navigationToolbarItems: some CustomizableToolbarContent {
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
      .onChange(of: model.templates?.persistent) { _, new in
        onTemplatePersistent(new)
        reload()
      }
      .onChange(of: model.processors?.persistent) { _, new in
        onRendererPersistent(new)
        reload()
      }
      .onChange(of: model.pageZoom) { _, new in onZoom(new) }
      .onChange(of: model.currentScrollY) { _, new in onScrollY(new) }
      .onChange(of: model.showsTOC) { _, new in onShowsTOC(new) }
  }
}

/// Publishes the per-window scene values commands rely on. Lifted
/// out of `DocumentView.body` to keep the modifier chain short enough
/// for the type-checker. Choice models live on `DocumentModel`; we
/// publish whatever it has — `nil` until `bindSettings` runs, which
/// is what the consumers (`RenderingCommands`) already handle.
private struct SceneValuesModifier: ViewModifier {
  let model: DocumentModel
  let renameContext: RenameContext

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.documentModel, model)
      .focusedSceneValue(\.viewerRenameContext, renameContext)
  }
}

/// Brings a toolbar `Menu` icon down to the visual size of sibling
/// toolbar buttons. SwiftUI hosts toolbar menus as `NSMenuToolbarItem`
/// at AppKit's larger metric, and font / imageScale / controlSize all
/// get dropped at the bridge — only `.scaleEffect` survives because it
/// runs at the SwiftUI compositor before AppKit sees the rendered
/// layer. Hit-testing keeps the original frame, which is fine.
private let toolbarMenuIconScale: CGFloat = 0.8

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
