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
struct ContentView: View {
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
  /// find bar, status bar, and a navigation toolbar (back/forward/
  /// reload, zoom, find, TOC, status-bar toggle).
  @ViewBuilder
  private func documentChrome(model: DocumentModel) -> some View {
    NavigationSplitView {
      TOCSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } detail: {
      WebView(model.page)
        .overlay {
          if !model.isPageRendered {
            model.pageBackgroundColor.allowsHitTesting(false)
          }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
          if model.find.isVisible {
            FindBar(model: model.find)
              .transition(.move(edge: .top))
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if Defaults.shared.showsStatusBar {
            StatusBar(
              stats: model.stats,
              wordsPerMinute: Defaults.shared.readingWordsPerMinute)
          }
        }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar { toolbarContent(model: model) }
    .focusedSceneValue(\.documentModel, model)
    .onAppear { wireLinkBridge(model: model) }
  }

  @ToolbarContentBuilder
  private func toolbarContent(model: DocumentModel) -> some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Action.back(model).toolbarItem(imageOnly: true)
      Action.forward(model).toolbarItem(imageOnly: true)
      Action.reload(model).toolbarItem(imageOnly: true)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Action.toggleTOC(model).toolbarItem(imageOnly: true)
      Action.zoomOut(model).toolbarItem(imageOnly: true)
      Action.resetZoom(model).toolbarItem(imageOnly: true)
      Action.zoomIn(model).toolbarItem(imageOnly: true)
      Action.find(model.find).toolbarItem(imageOnly: true)
      Action.toggleStatusBar().toolbarItem(imageOnly: true)
    }
  }

  /// Wire `LinkBridge`'s non-macOS callbacks so external links route
  /// through SwiftUI's `openURL` and `finder://` reveal links are
  /// surfaced as a no-op log. The bridge instance lives inside the
  /// model; we install the callbacks on first mount.
  ///
  /// `onMarkdownLink` is wired by `DocumentModel.wireBridges` itself
  /// (in shared code), so in-window `.md → .md` navigation works
  /// without anything here.
  private func wireLinkBridge(model: DocumentModel) {
    // No-op for v1 — DocumentModel.wireBridges handles the
    // markdown-link case; external URLs land here only when the user
    // taps a non-markdown http(s) link in the preview. The bridge's
    // `#if !os(macOS)` fallback logs the missing callback; install a
    // proper `onExternalURL` once the visionOS spec for "open in
    // browser" is decided. Kept as a hook point so the wiring path
    // is obvious to the next reader.
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
      kind: .document)
    model = created
    return created
  }
}

#endif
