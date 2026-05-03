import AppKit
import GalleyCoreKit
import SwiftUI
import WebKit

struct ContentView: View {
  @Binding var fileURL: URL?
  @Environment(AppBoot.self) private var boot
  @Environment(ViewerAppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  @State private var model = DocumentModel()
  @State private var didRestore = false
  @State private var hostWindow: NSWindow?

  /// Per-window persisted back/forward stack. SwiftUI's `@SceneStorage`
  /// gives each WindowGroup window its own keyspace, so two windows
  /// each get their own history that survives app relaunch.
  @SceneStorage("\(keyPrefix).history") private var historyJSON: String = ""

  /// Per-window renderer / template overrides, encoded as
  /// `{id, name}` JSON blobs from `SceneChoice.persistent`. `nil`
  /// means "no override — use the global selection." Only honored
  /// when `AppModel.enablePerDocumentOverrides` is on.
  @SceneStorage("\(keyPrefix).overrideRendererPersistent")
  private var overrideRendererPersistent: String?
  @SceneStorage("\(keyPrefix).overrideTemplatePersistent")
  private var overrideTemplatePersistent: String?

  /// Per-window zoom factor. Mirrored to/from `model.pageZoom` so the
  /// window comes back at the size the user left it.
  @SceneStorage("\(keyPrefix).pageZoom") private var pageZoomStored: Double = 1

  /// Per-window resting scroll position in pixels. Mirrored from
  /// `model.currentScrollY` whenever the user pauses scrolling, so a
  /// relaunched window comes back at the same place. Hydrated into
  /// `model` at first bind / restore.
  @SceneStorage("\(keyPrefix).scrollY") private var scrollYStored: Double = 0

  var body: some View {
    if let appModel = boot.model {
      readyBody(appModel: appModel)
    } else {
      // Boot in flight (processor discovery). Keep the window hidden
      // so the user never sees a pre-render flash. ContentView stays
      // mounted so `@SceneStorage` and the WindowGroup URL binding
      // hydrate normally; only the body underneath swaps.
      Color.clear
        .background(BootWindowHider())
    }
  }

  @ViewBuilder
  private func readyBody(appModel: AppModel) -> some View {
    Group {
      if fileURL != nil {
        WebView(model.page)
          .overlay(alignment: .bottom) {
            if let error = model.lastError {
              Text(error)
                .padding(8)
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
                .padding()
            }
          }
      } else {
        // Empty placeholder while the launch open panel is up. The
        // window is hidden via alphaValue=0 in `launchTask`, so the
        // user only sees the open panel — never an "open a document"
        // label.
        Color.clear
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
          window?.alphaValue = (model.documentURL == nil) ? 0 : 1
        }
        if let window {
          // Merge into the frontmost window's tab group if this open
          // came in under the `newTab` behavior. Has to happen as
          // soon as the new window exists so the user never sees
          // it as a separate floating window first.
          if let host = appDelegate.consumePendingTabHost(),
             host !== window
          {
            host.addTabbedWindow(window, ordered: .above)
          }
          appDelegate.registerWindow(
            window,
            initialURL: fileURL
          ) { newURL in
            replaceDocument(with: newURL)
          }
        }
      },
      onDetach: { window in
        if let window { appDelegate.unregisterWindow(window) }
      }))
    .toolbar(id: "viewer.main") { toolbarContent(appModel: appModel) }
    .modifier(SceneValuesModifier(
      model: model,
      renameContext: RenameContext(
        url: model.documentURL,
        apply: { newURL in
          appDelegate.record(newURL)
          if fileURL != newURL { fileURL = newURL }
        })))
    .navigationTitle(model.documentURL?.lastPathComponent
      ?? fileURL?.lastPathComponent
      ?? "Markdown Preview")
    .task(id: fileURL) { await launchTask(appModel: appModel) }
    .modifier(ChangeHandlers(
      model: model,
      appModel: appModel,
      onDocumentBound: handleDocumentBound,
      onTemplatePersistent: mirrorPerFileTemplate,
      onRendererPersistent: mirrorPerFileRenderer,
      onZoom: mirrorPerFileZoom,
      onScrollY: mirrorPerFileScrollY,
      reload: reloadModel))
    .navigationDocument(model.documentURL ?? URL.homeDirectory)
  }

  /// First time content is bound (whether via initial bind, restore,
  /// or in-window navigation), reveal the window and promote it from
  /// "placeholder" to "real document window" so future dispatches can
  /// tab onto it.
  private func handleDocumentBound(_ new: URL?) {
    saveHistory()
    if let window = hostWindow {
      appDelegate.updateCurrentURL(window, new)
    }
    guard new != nil else { return }
    hostWindow?.alphaValue = 1
    if let window = hostWindow {
      appDelegate.markWindowReady(window)
    }
  }

  private func reloadModel() {
    Task { await model.reload() }
  }

  /// Read `PerFileStateStore` for `url` and patch any value the
  /// scene's storage hasn't already overridden. Leaves untouched
  /// fields the user has explicitly modified in this scene
  /// (recognized by their value being non-default).
  private func hydrateFromPerFileState(url: URL) {
    let stored = Defaults.shared
      .perFileStateStore[PerFileState.key(for: url), default: .init()]
    if pageZoomStored == 1.0, let z = stored.pageZoom {
      pageZoomStored = z
    }
    if scrollYStored == 0, let y = stored.scrollY {
      scrollYStored = y
    }
    if overrideTemplatePersistent == nil,
       let template = stored.templatePersistent
    {
      overrideTemplatePersistent = template
    }
    if overrideRendererPersistent == nil,
       let renderer = stored.rendererPersistent
    {
      overrideRendererPersistent = renderer
    }
  }

  /// Persist the new value to both `@SceneStorage` (for restoration
  /// of *this* window) and `PerFileStateStore` (for the next time
  /// this URL is opened anywhere). `keyPath` writes the field on the
  /// per-file record — `nil` for "back to default" so the store's
  /// dictionary doesn't accumulate dead entries.
  private func mirrorPerFileZoom(_ value: Double) {
    pageZoomStored = value
    writePerFileState { $0.pageZoom = value == 1.0 ? nil : value }
  }

  private func mirrorPerFileScrollY(_ value: Double) {
    scrollYStored = value
    writePerFileState { $0.scrollY = value == 0 ? nil : value }
  }

  private func mirrorPerFileTemplate(_ value: String?) {
    overrideTemplatePersistent = value
    writePerFileState { $0.templatePersistent = value }
  }

  private func mirrorPerFileRenderer(_ value: String?) {
    overrideRendererPersistent = value
    writePerFileState { $0.rendererPersistent = value }
  }

  private func writePerFileState(
    _ mutation: (inout PerFileState) -> Void
  ) {
    guard let url = model.documentURL
    else { return }
    mutation(&Defaults.shared
      .perFileStateStore[PerFileState.key(for: url), default: .init()])
  }

  /// Swap this window's bound document for `newURL` in place. Used by
  /// the `replaceCurrent` open behavior. Updates the WindowGroup
  /// binding so state restoration follows, and rebinds the model so
  /// history/watcher restart on the new URL.
  private func replaceDocument(with newURL: URL) {
    appDelegate.record(newURL)
    if fileURL != newURL { fileURL = newURL }
    let line = appDelegate.consumePendingScrollLine(for: newURL)
    Task {
      // Same URL re-dispatch (e.g. BBEdit's preview script firing
      // again on a file already showing): just scroll, don't tear
      // down history. A fresh URL takes the full bind path.
      if model.documentURL == newURL, let line {
        await model.scrollToSourceLine(line)
      } else {
        await model.bind(to: newURL, scrollToLine: line)
      }
    }
  }

  /// Drives launch wiring + initial bind + FTUE picker. Re-runs when
  /// `fileURL` changes — typically once: nil → picked URL.
  /// Only mounted once `boot.model` is non-nil, so by the time this
  /// fires processor discovery has completed and the persisted pick
  /// has been decoded against the live catalog.
  private func launchTask(appModel: AppModel) async {
    // Fresh open of a file we've seen before: hydrate the
    // window's `@SceneStorage` slots from `PerFileStateStore` so
    // zoom / scroll / per-document overrides come back the way the
    // user left them, even though this is a brand-new scene with no
    // restoration data of its own. State-restored windows skip this
    // — their `@SceneStorage` already carries the most recent
    // window-specific values, which beat per-file defaults.
    let willRestore = !didRestore && decodeHistory(historyJSON) != nil
    if let fileURL, !willRestore {
      hydrateFromPerFileState(url: fileURL)
    }

    // Hydrate zoom from scene storage *before* the first render so
    // the page comes up at the right size — `setZoom` only triggers
    // a JS update; the next render reads `pageZoom` to inject CSS.
    model.setZoom(pageZoomStored)
    model.bindSettings(
      appModel,
      templatePersistent: overrideTemplatePersistent,
      processorPersistent: overrideRendererPersistent)

    // Keep the delegate's appModel reference fresh — `application(_:open:)`
    // and Open Recent dispatch consult `openBehavior` from there.
    appDelegate.appModel = appModel

    // First view to come up captures `openWindow` for the delegate
    // so Finder file opens and File > Open Recent route into new
    // windows. install() returns true when launch-time URLs flushed.
    let flushed = installOpenWindowHandlerIfNeeded()

    // SwiftUI fires `.task(id:)` more than once even when the id
    // is stable (the modifier is recreated on body re-eval). If a
    // previous fire already bound or restored content, we're done.
    if model.documentURL != nil { return }

    // Restore a saved session (back/forward stack) for this scene.
    if !didRestore, let snapshot = decodeHistory(historyJSON) {
      didRestore = true
      await model.restore(
        snapshot: snapshot,
        initialScrollY: scrollYStored > 0 ? scrollYStored : nil)
      if let current = model.documentURL { appDelegate.record(current) }
      return
    }

    // Initial bind for a freshly-opened URL.
    if let fileURL {
      appDelegate.record(fileURL)
      let line = appDelegate.consumePendingScrollLine(for: fileURL)
      await model.bind(
        to: fileURL,
        scrollToLine: line,
        initialScrollY: scrollYStored > 0 ? scrollYStored : nil)
      return
    }

    // application(_:open:) URLs are spawning real windows of their
    // own. Drop the placeholder.
    if flushed {
      dismiss()
      return
    }

    // Truly empty placeholder — wait for launch (and any in-flight
    // state restoration) to settle, then run the FTUE picker.
    await runLaunchPicker()
  }

  /// FTUE: wait for app launch to settle, then run the open panel.
  /// If the user picks files, route the first into this same window
  /// (by writing the binding) and any extras into new windows;
  /// cancel closes the placeholder.
  ///
  /// The window is already alpha=0 from `WindowAccessor` and will
  /// stay hidden until `model.documentURL` becomes non-nil — set
  /// when the picked file binds.
  private func runLaunchPicker() async {
    // Wait for AppKit to finish launching. State restoration is
    // complete by then, so any restored window's URL has already
    // landed in its scene's binding — this window is genuinely
    // the empty placeholder, not a restored window in transit.
    while !appDelegate.didFinishLaunching {
      try? await Task.sleep(for: .milliseconds(50))
      if Task.isCancelled { return }
    }
    if Task.isCancelled || fileURL != nil { return }

    // Settle window: if `application(_:open:)` fired a URL into the
    // existing `openHandler` (warm-launch dispatch), the spawned
    // doc window may still be attaching. Give it a moment to arrive
    // and register before we decide whether the picker is needed.
    try? await Task.sleep(for: .milliseconds(150))
    if Task.isCancelled || fileURL != nil { return }

    // A real document window already exists (either spawned from a
    // dispatched URL or restored from a previous session). This
    // placeholder is redundant — close it instead of pestering the
    // user with the FTUE open panel.
    if appDelegate.hasAnyDocumentWindow() {
      dismiss()
      return
    }

    let picks = await appDelegate.runOpenPanel()
    // An incoming dispatch can rebind this placeholder while the
    // panel is up — in that case the panel was cancelled out from
    // under us and `fileURL` is now non-nil. Don't dismiss the
    // window we just got handed a document for.
    if Task.isCancelled || fileURL != nil { return }
    guard let first = picks.first else {
      dismiss()
      return
    }
    for extra in picks.dropFirst() {
      appDelegate.record(extra)
      openWindow(value: extra)
    }
    appDelegate.record(first)
    fileURL = first
    // Setting `fileURL` re-fires `task(id: fileURL)` which binds
    // the model. The bind sets model.documentURL, which our
    // .onChange flips alphaValue=1 — revealing the window with
    // content already rendered.
  }

  @discardableResult
  private func installOpenWindowHandlerIfNeeded() -> Bool {
    guard appDelegate.openHandler == nil else { return false }
    let action = openWindow
    return appDelegate.install { url in action(value: url) }
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
    mainToolbarItems(appModel: appModel)
    zoomToolbarItems
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

/// Bundles every `.onChange` handler `readyBody` needs. Keeps the
/// view body short and isolates the mirroring logic between model
/// state and the enclosing scene's `@SceneStorage` slots.
private struct ChangeHandlers: ViewModifier {
  let model: DocumentModel
  let appModel: AppModel
  let onDocumentBound: (URL?) -> Void
  let onTemplatePersistent: (String?) -> Void
  let onRendererPersistent: (String?) -> Void
  let onZoom: (Double) -> Void
  let onScrollY: (Double) -> Void
  let reload: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: model.documentURL) { _, new in onDocumentBound(new) }
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
  }
}

/// Publishes the per-window scene values commands rely on. Lifted
/// out of `ContentView.body` to keep the modifier chain short enough
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

/// Pins `window.alphaValue = 0` while the AppModel is still booting.
/// Used by the boot branch of `ContentView.body`; once the body
/// swaps to `readyBody`, the regular `WindowAccessor` takes over
/// alpha control based on `documentURL`.
private struct BootWindowHider: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Hider() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Hider: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.alphaValue = 0
    }
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
      title: appModel.processors.selected.name,
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
      title: appModel.templates.selected.name,
      appModel: appModel,
      documentModel: docModel)
    .scaleEffect(toolbarMenuIconScale, anchor: .center)
    .help("Template")
  }
}
