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
/// `ContentView` once the window has a `DocumentModel` (built from a
/// restored snapshot or an inbound URL) — so this view always has a
/// concrete document and a hydrated `AppModel` to work with.
struct DocumentView: View {
  /// The window's document model — built and cached by `ContentView`
  /// (`DocumentModel.forScene` / `.open`), already populated and
  /// rendering. The view never constructs it, never owns persistence,
  /// and never observes it to mutate another model.
  let model: DocumentModel

  private var appModel: AppModel { model.appModel }
  private var recents: RecentDocumentsModel { AppModel.shared.recents }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

  init(model: DocumentModel) {
    self.model = model
  }

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
        // The window is always visible — no reveal gate. Resolve it
        // once to patch the AppKit tab-bar "+" (so a user "+" click
        // opens via the Open panel + activity URL). Help skips it.
        // Inbound-URL routing lives in `ContentView`, not here.
        guard let window, window !== hostWindow else { return }
        hostWindow = window
        window.alphaValue = 1
        if model.kind == .document {
          NewTabAction.install(on: window)
        }
      }
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
      Action.zoomOut(model.zoom).toolbarItem()
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "zoomReset", placement: .confirmationAction) {
      Action.resetZoom(model.zoom).toolbarItem()
    }
    .defaultCustomization(.hidden)

    ToolbarItem(id: "zoomIn", placement: .confirmationAction) {
      Action.zoomIn(model.zoom).toolbarItem()
    }
    .defaultCustomization(.hidden)
  }

  private var zoomLabel: String {
    let percent = Int((model.zoom.zoomScale * 100).rounded())
    return "\(percent)%"
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
