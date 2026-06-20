//
//  MoreMenu.swift
//  Galley
//
//  Created by Anton Leuski on 6/17/26.
//

#if os(visionOS)
import SwiftUI
import GalleyCoreKit

struct MoreMenu: View {
  @State var isFilePickerPresented = false
  @Bindable var model: DocumentModel
  @Bindable var appModel = AppModel.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
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

      templateMenu(documentModel: model)
        .disabled(!model.documentURL.isFileURL)
        .help(
          model.documentURL.isFileURL
          ? ""
          : "Rendered on Mac — change template in Galley on your Mac.")
      colorSchemeMenu(documentModel: model)
        .disabled(!model.documentURL.isFileURL)
        .help(
          model.documentURL.isFileURL
          ? ""
          : "Rendered on Mac — change color scheme on your Mac.")
      if appModel.processors.values.count > 1 {
        processorMenu(documentModel: model)
      }

      Divider()

      Action.settings().menuItem()
      Action.howToMakeTemplate().menuItem()

    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier(ViewerA11yID.Toolbar.more)
    // The "Open Document…" entry in the More menu drives this. Picks
    // fire an activity URL (open-behavior handled in `DocumentSceneContent`) —
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

  /// Open Recent submenu. Each pick fires an activity URL; the user's
  /// open-behavior (replace / new window) is applied in `DocumentSceneContent`.
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
