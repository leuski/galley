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
  @Bindable var model: DocumentModel
  @State private var isPresented = false
  @Environment(AppModel.self) var appModel

  var body: some View {
    Menu {
      Action.open(isPresented: $isPresented, appModel: appModel).menuItem()

      if !appModel.recents.urls.isEmpty {
        Action.openRecentMenu(appModel: appModel)
      }

      Divider()

      Action.toggleStatusBar().menuItem()

      Divider()

      TemplateMenu(documentModel: model)
        .disabled(!model.documentURL.isFileURL)
        .help(
          model.documentURL.isFileURL
          ? ""
          : "Rendered on Mac — change template in Galley on your Mac.")
      ColorSchemeMenu(documentModel: model)
        .disabled(!model.documentURL.isFileURL)
        .help(
          model.documentURL.isFileURL
          ? ""
          : "Rendered on Mac — change color scheme on your Mac.")
      if appModel.processors.values.count > 1 {
        ProcessorMenu(documentModel: model)
      }

      Divider()

      Action.settings().menuItem()
      Action.howToMakeTemplate().menuItem()

    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .modifier(OpenFileModifier(isPresented: $isPresented))
    .accessibilityIdentifier(ViewerA11yID.Toolbar.more)
  }
}
#endif
