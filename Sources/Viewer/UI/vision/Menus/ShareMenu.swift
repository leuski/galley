//
//  ShareMenu.swift
//  Galley
//
//  Created by Anton Leuski on 6/17/26.
//

#if os(visionOS)
import SwiftUI
import GalleyCoreKit

struct ShareMenu: View {
  @Bindable var model: DocumentModel

  var body: some View {
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
}
#endif
