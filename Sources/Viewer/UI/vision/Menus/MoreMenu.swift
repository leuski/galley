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

  var body: some View {
    Menu {
      Action.open(isPresented: $isPresented).menuItem()

      if !AppModel.shared.recents.urls.isEmpty {
        Action.openRecentMenu()
      }

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
      if AppModel.shared.processors.values.count > 1 {
        processorMenu(documentModel: model)
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
