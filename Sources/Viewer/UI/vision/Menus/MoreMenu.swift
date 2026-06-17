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
  @Binding var isFilePickerPresented: Bool
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
