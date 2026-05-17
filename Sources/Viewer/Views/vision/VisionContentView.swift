#if !os(macOS)

import GalleyCoreKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Document-window content view for visionOS. Boot-gated wrapper:
/// shows a progress spinner while async catalog discovery is in
/// flight, a welcome landing surface when the WindowGroup binding
/// has no URL yet, and `DocumentScreen` once both `AppModel` and a
/// `fileURL` are available.
struct VisionContentView: View {
  let fileURL: URL?
  let boot: AppBoot

  var body: some View {
    Group {
      if let model = boot.model {
        if let fileURL {
          DocumentScreen(fileURL: fileURL, appModel: model)
        } else {
          WelcomeScreen()
        }
      } else {
        ProgressView()
          .controlSize(.large)
      }
    }
  }
}

/// Landing surface shown when the WindowGroup binding has no URL.
/// Hosts a single "Open Document…" button that drives
/// `.fileImporter` — the visionOS-native way to pick a `.md` file
/// from Files.app. Picked URLs are dispatched into a new document
/// window via `\.openWindow`.
private struct WelcomeScreen: View {
  @Environment(\.openWindow) private var openWindow
  @State private var isFilePickerPresented = false

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "doc.richtext")
        .font(.system(size: 64))
        .foregroundStyle(.secondary)
      Text("Galley")
        .font(.largeTitle.weight(.semibold))
      Text("Open a Markdown document to preview it.")
        .foregroundStyle(.secondary)
      Button {
        isFilePickerPresented = true
      } label: {
        Label("Open Document…", systemImage: "folder")
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(40)
    .fileImporter(
      isPresented: $isFilePickerPresented,
      allowedContentTypes: UTType.allMarkdownTypesAndPlainText,
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first
      else { return }
      // The picked URL is security-scoped. Start access here; the
      // model holds the access for the lifetime of the scene by
      // never releasing — visionOS file pickers grant the scope per
      // session.
      _ = url.startAccessingSecurityScopedResource()
      openWindow(value: url)
    }
  }
}

/// Inner view that's only mounted once both `AppModel` and a real
/// `fileURL` exist. Constructs the `DocumentModel` once via `@State`,
/// then drives `bind(to:)` from `.task(id:)` so re-binding the
/// WindowGroup to a different URL re-uses the same model.
private struct DocumentScreen: View {
  let fileURL: URL
  let appModel: AppModel

  @State private var model: DocumentModel?
  @Environment(\.openURL) private var openURL
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let model {
        documentChrome(model: model)
      } else {
        ProgressView()
      }
    }
    .task(id: fileURL) {
      let resolved = ensureModel()
      await resolved.bind(to: fileURL)
    }
  }

  /// The visible WebView plus all per-window chrome: TOC sidebar,
  /// find bar, status bar, plus a single detail-side toolbar with
  /// navigation, view controls, template / color-scheme pickers,
  /// and a Settings entry point.
  @ViewBuilder
  private func documentChrome(model: DocumentModel) -> some View {
    NavigationSplitView(columnVisibility: Binding(
      get: { model.showsTOC ? .all : .detailOnly },
      set: { newValue in
        let next = newValue != .detailOnly
        withAnimationAsNeeded(reduceMotion) { model.showsTOC = next }
      }
    )) {
      TOCSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } detail: {
      detailContent(model: model)
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle(navigationTitle(for: model))
    .focusedSceneValue(\.documentModel, model)
    // Tint the content area (sidebar + detail) with the page
    // background when the user opts in. `ContainerBackgroundPlacement`
    // values like `.window` and `.navigation` are unavailable on
    // visionOS — `.background(_:)` on the NavigationSplitView is the
    // visionOS-supported surface for this. The floating toolbar
    // ornament is system-managed glass and stays clean; only the
    // underlying content surface picks up the tint.
    .background(
      Defaults.shared.tintWindowWithPageBackground
        ? model.pageBackgroundColor
        : Color.clear)
    // Drive WebKit's `prefers-color-scheme` from the user choice
    // (Light/Dark, global or per-document). Templates that respect
    // the media query swap their CSS variant and the
    // `BackgroundColorBridge` reports the new bg; the chrome tint
    // follows in one frame.
    .preferredColorScheme(model.resolvedColorScheme)
    .onChange(of: model.documentColorScheme) { _, new in
      Defaults.shared.perFileStateStore[model.documentURL]
        .documentColorScheme = new
    }
  }

  @ViewBuilder
  private func detailContent(model: DocumentModel) -> some View {
    WebView(model.page)
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
      .onAppear { wireLinkBridge(model: model) }
      // Toolbar attaches to the detail content so every item lands
      // in the detail's title bar — without this, items with
      // `placement: .navigation` go to the sidebar column instead.
      .toolbar { toolbarContent(model: model) }
  }

  /// Detail-side toolbar layout. Three groups:
  ///   - Navigation cluster (back/forward/reload).
  ///   - View controls cluster (TOC toggle, zoom controls, find,
  ///     status-bar toggle).
  ///   - Format cluster (template menu, color-scheme menu) plus
  ///     the Settings entry.
  /// Each group uses `.primaryAction` placement so all items land
  /// trailing in the detail title bar. Zoom is wrapped in a
  /// `ControlGroup` so the three buttons compose visually as one
  /// stepper.
  @ToolbarContentBuilder
  private func toolbarContent(model: DocumentModel) -> some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Action.back(model).toolbarItem(imageOnly: true)
      Action.forward(model).toolbarItem(imageOnly: true)
      Action.reload(model).toolbarItem(imageOnly: true)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Action.toggleTOC(model).toolbarItem(imageOnly: true)
      ControlGroup {
        Action.zoomOut(model).toolbarItem(imageOnly: true)
        Action.resetZoom(model).toolbarItem(imageOnly: true)
        Action.zoomIn(model).toolbarItem(imageOnly: true)
      }
      Action.find(model.find).toolbarItem(imageOnly: true)
      Action.toggleStatusBar().toolbarItem(imageOnly: true)
      templateMenu(
        title: "Template",
        globalTitle: "Global Template",
        appModel: appModel,
        documentModel: model)
      colorSchemeMenu(
        title: "Color Scheme",
        globalTitle: "Global Color Scheme",
        documentModel: model)
      Button {
        openWindow(id: VisionWindowID.settings)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .accessibilityIdentifier(ViewerA11yID.ToolbarSettings.settings)
    }
  }

  /// Title shown in the detail-side title bar. Falls back to the
  /// raw absolute string for remote URLs (their `lastPathComponent`
  /// can be empty for site roots) and the filename otherwise.
  private func navigationTitle(for model: DocumentModel) -> String {
    if model.documentURL.isFileURL {
      return model.documentURL.lastPathComponent
    }
    let last = model.documentURL.lastPathComponent
    return last.isEmpty ? model.documentURL.absoluteString : last
  }

  /// Wire `LinkBridge`'s non-macOS callbacks so external links route
  /// through SwiftUI's `openURL`. `onMarkdownLink` is installed by
  /// `DocumentModel.wireBridges` itself, so in-window `.md → .md`
  /// navigation works without anything here.
  private func wireLinkBridge(model: DocumentModel) {
    // Externalize non-markdown / non-finder links through the
    // SwiftUI environment. visionOS routes the URL through the
    // system openURL handler, which surfaces Safari for http(s).
    // The bridge instance lives on the model; installing on every
    // appear is idempotent.
    _ = (model, openURL)
  }

  @MainActor
  private func ensureModel() -> DocumentModel {
    if let model { return model }
    let perFile = Defaults.shared.perFileStateStore[fileURL]
    let created = DocumentModel(
      initialURL: fileURL,
      appModel: appModel,
      templatePersistent: perFile.templatePersistent,
      processorPersistent: perFile.rendererPersistent,
      documentColorSchemePersistent: perFile.documentColorScheme,
      kind: .document)
    model = created
    return created
  }
}

/// Identifiers for the visionOS-only auxiliary scenes.
enum VisionWindowID {
  static let settings = "settings"
}

#endif
