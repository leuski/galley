//
//  VisionDocumentScreen.swift
//  Galley
//
#if os(visionOS)
import GalleyCoreKit
import SwiftUI
import WebKit

/// The visionOS document surface for a single window. The model is built
/// and cached by `DocumentSceneContent` (`DocumentModel.forScene` / `.open`),
/// already populated, rendering, and owning its own persistence + reload
/// — this view only renders chrome and forwards user intent as activity
/// URLs. Inbound-URL routing lives in `DocumentSceneContent`, not here.
struct VisionDocumentScreen: View {
  @Bindable var model: DocumentModel

  var body: some View {
    HStack(spacing: 0) {
      if model.showsTOC {
        VStack(alignment: .leading) {
          TOCSidebar(model: model)
            .padding(.top, 16)
        }
        .frame(width: 340)
        .transition(.move(edge: .leading).combined(with: .opacity))
      }
      DocumentMainContent(model: model)
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
    .background(
      Defaults.shared.tintWindowWithPageBackground
      ? model.pageBackgroundColor
      : Color.clear)
    .preferredColorScheme(model.resolvedColorScheme)
  }
}
#endif
