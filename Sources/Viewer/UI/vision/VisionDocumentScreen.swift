//
//  VisionDocumentScreen.swift
//  Galley
//
#if os(visionOS)
import GalleyCoreKit
import SwiftUI
import WebKit

/// The visionOS document surface for a single window. The model is built
/// and cached by `ContentView` (`DocumentModel.forScene` / `.open`),
/// already populated, rendering, and owning its own persistence + reload
/// — this view only renders chrome and forwards user intent as activity
/// URLs. Inbound-URL routing lives in `ContentView`, not here.
struct VisionDocumentScreen: View {
  let model: DocumentModel

  @State private var isFilePickerPresented = false

  init(model: DocumentModel) {
    self.model = model
  }

  var body: some View {
    documentChrome(model: model)
      // The "Open Document…" entry in the More menu drives this. Picks
      // fire an activity URL (open-behavior handled in `ContentView`) —
      // the same path every other open takes.
      .fileImporter(
        isPresented: $isFilePickerPresented,
        allowedContentTypes: MarkdownFileTypes.allTypesAndPlainText,
        allowsMultipleSelection: false
      ) { result in
        guard case .success(let urls) = result, let url = urls.first
        else { return }
        _ = url.startAccessingSecurityScopedResource()
        GalleyViewerRequestActivity(url: url).open()
      }
  }

  /// The visible WebView plus all per-window chrome: TOC sidebar,
  /// find bar, status bar, plus a bottom-ornament toolbar with
  /// navigation, view controls, template / color-scheme pickers,
  /// and a Settings entry point.
  @ViewBuilder
  private func documentChrome(model: DocumentModel) -> some View {
    HStack(spacing: 0) {
      if model.showsTOC {
        VStack(alignment: .leading) {
          TOCSidebar(model: model)
            .padding(.top, 16)
        }
        .frame(width: 340)
        .transition(.move(edge: .leading).combined(with: .opacity))
      }
      detailContent(model: model)
        .frame(minWidth: 700, minHeight: 900)
        .background(
          GeometryReader { proxy in
            Color.clear
              .onChange(of: proxy.size.width, initial: true) { _, width in
                model.liveDetailWidth = width
              }
          }
        )
        .frame(width: model.pinnedDetailWidth)
    }
    .focusedSceneValue(\.documentModel, model)
    .background(
      Defaults.shared.tintWindowWithPageBackground
      ? model.pageBackgroundColor
      : Color.clear)
    .preferredColorScheme(model.resolvedColorScheme)
  }

  @ViewBuilder
  private func detailContent(model: DocumentModel) -> some View {
    WebView(model.page)
      .navigationTitle(
        model.kind == .help
        ? Text("Help")
        : Text(model.documentURL.lastPathComponent))
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
      .toolbar { toolbarContent(model: model) }
  }

  @ToolbarContentBuilder
  private func toolbarContent(model: DocumentModel) -> some ToolbarContent {
    ToolbarItemGroup(placement: .bottomOrnament) {
      Action.back(model).button()
      Action.forward(model).button()
      Action.reload(model).button()

      Spacer()

      Action.toggleTOC(model).button()

      Spacer()

      ControlGroup {
        Action.zoomOut(model.zoom).button()
        Action.resetZoom(model.zoom).button()
        Action.zoomIn(model.zoom).button()
      }

      Spacer()

      Action.find(model.find).button()

      Spacer()

      ShareMenu(model: model)

      MoreMenu(isFilePickerPresented: $isFilePickerPresented, model: model)
    }
  }
}
#endif
