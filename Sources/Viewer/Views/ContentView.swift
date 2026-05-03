import AppKit
import GalleyCoreKit
import SwiftUI
import WebKit

struct ContentView: View {
  @Binding var fileURL: URL?
  @Environment(AppBoot.self) private var boot
  @Environment(ViewerAppDelegate.self) private var appDelegate
  @Environment(WindowDispatcher.self) private var dispatcher
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
    // SwiftUI's `WindowGroup(for: URL.self)` always exposes a
    // `Binding<URL?>` even when our architecture guarantees a non-
    // nil URL: every doc window is spawned via `openWindow(value:)`
    // or restored with a saved URL. The optional is purely a
    // SwiftUI API constraint. If a stray nil ever surfaces during
    // a transient SwiftUI binding state, WebView renders an empty
    // page for the few milliseconds until the URL settles.
    WebView(model.page)
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
          window?.alphaValue = (model.documentURL == nil) ? 0 : 1
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
  /// or in-window navigation), reveal the window and update the
  /// registry's current URL so re-opens of the same URL focus this
  /// existing window instead of spawning a new one.
  private func handleDocumentBound(_ new: URL?) {
    saveHistory()
    if let window = hostWindow {
      dispatcher.updateCurrentURL(window, new)
    }
    guard new != nil else { return }
    hostWindow?.alphaValue = 1
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
    let line = dispatcher.consumePendingScrollLine(for: newURL)
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

  /// Drives initial bind for a document window. Only mounted once
  /// `boot.model` is non-nil, so by the time this fires processor
  /// discovery has completed and the persisted pick has been
  /// decoded against the live catalog.
  ///
  /// Document windows are always spawned with a non-nil URL — the
  /// FTUE / launch-bootstrap path lives in `WelcomeView` now, so
  /// `ContentView.fileURL` can never legitimately be nil at task
  /// time outside of an in-flight rebind.
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
      let line = dispatcher.consumePendingScrollLine(for: fileURL)
      await model.bind(
        to: fileURL,
        scrollToLine: line,
        initialScrollY: scrollYStored > 0 ? scrollYStored : nil)
    }
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
