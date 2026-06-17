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
  @Environment(\.openURL) private var openURL
  @Environment(\.openWindow) private var openWindow
  private var appModel: AppModel { model.appModel }
  private var recents: RecentDocumentsModel { AppModel.shared.recents }

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

      shareMenu(model: model)

      moreMenu(model: model)
    }
  }

  @ViewBuilder
  private func shareMenu(model: DocumentModel) -> some View {
    Menu {
      if model.documentURL.isFileURL {
        ShareLink(
          item: model.documentURL,
          subject: Text(model.documentURL.lastPathComponent),
          message: Text(model.documentURL.lastPathComponent)
        ) {
          Label("Markdown Source", systemImage: "doc.text")
        }
        .accessibilityIdentifier(ViewerA11yID.Toolbar.shareMarkdown)
      }
      ShareLink(
        item: model.pdfExport,
        preview: SharePreview(
          model.pdfExport.suggestedName,
          image: Image(systemName: "doc.richtext"))
      ) {
        Label("Rendered PDF", systemImage: "doc.richtext")
      }
      .accessibilityIdentifier(ViewerA11yID.Toolbar.sharePDF)
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    .accessibilityIdentifier(ViewerA11yID.Toolbar.share)
  }

  @ViewBuilder
  private func moreMenu(model: DocumentModel) -> some View {
    Menu {
      Button {
        isFilePickerPresented = true
      } label: {
        Label("Open Document…", systemImage: "folder")
      }

      openRecentMenu

      Divider()

      Action.toggleStatusBar().menuItem()

      Divider()

      templateMenu(
        appModel: appModel,
        documentModel: model)
      .disabled(!model.documentURL.isFileURL)
      .help(
        model.documentURL.isFileURL
        ? ""
        : "Rendered on Mac — change template in Galley on your Mac.")
      colorSchemeMenu(
        appModel: appModel,
        documentModel: model)
      .disabled(!model.documentURL.isFileURL)
      .help(
        model.documentURL.isFileURL
        ? ""
        : "Rendered on Mac — change color scheme on your Mac.")
      if appModel.processors.values.count > 1 {
        processorMenu(
          appModel: appModel,
          documentModel: model)
      }

      Divider()

      Button {
        openWindow(id: SettingsScene.id)
      } label: {
        Label("Settings…", systemImage: "gearshape")
      }
      .accessibilityIdentifier(ViewerA11yID.ToolbarSettings.settings)

      if let helpURL = Bundle.main.url(
        forResource: "template-authoring",
        withExtension: "md") {
        Button {
          GalleyViewerRequestActivity(url: helpURL).open()
        } label: {
          Label(
            "How to Make a Template",
            systemImage: "questionmark.circle")
        }
        .accessibilityIdentifier(ViewerA11yID.HelpMenu.templateAuthoring)
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier(ViewerA11yID.Toolbar.more)
  }

  /// Open Recent submenu. Each pick fires an activity URL; the user's
  /// open-behavior (replace / new window) is applied in `ContentView`.
  @ViewBuilder
  private var openRecentMenu: some View {
    @Bindable var recents = AppModel.shared.recents
    if !recents.urls.isEmpty {
      Menu {
        ForEach(recents.urls, id: \.self) { url in
          Button {
            if let fresh = recents.resolveRecentURL(url) {
              GalleyViewerRequestActivity(url: fresh).open()
            }
          } label: {
            Label(url.lastPathComponent, systemImage: "doc.text")
          }
        }
        Divider()
        Button("Clear Menu", role: .destructive) {
          recents.clearAll()
        }
      } label: {
        Label("Open Recent", systemImage: "clock")
      }
    }
  }
}
#endif
