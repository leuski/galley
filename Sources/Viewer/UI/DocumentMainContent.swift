//
//  DocumentMainContent.swift
//  Galley
//
//  Created by Anton Leuski on 6/17/26.
//

import SwiftUI
import GalleyCoreKit
import WebKit

struct DocumentMainContent: View {
  @Bindable var model: DocumentModel

  var body: some View {
    WebView(model.page)
      .focusedSceneValue(\.documentModel, model)
      .frame(minWidth: webViewMinWidth)
      .navigationTitle(
        model.kind == .help
        ? Text("Help")
        : Text(model.documentURL.lastPathComponent))
    // The WebView's pre-paint canvas paints system-white during
    // the gap between mount and the first HTML layout — visible
    // as a white flash on tab open / reload regardless of CSS.
    // Cover that gap with the resolved page bg (which falls
    // back through last-seen → system bg) until `isPageRendered`
    // flips true via the BackgroundColorBridge post-layout fire.
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
      .toolbar(id: model.kind == .document ? "viewer.main" : "viewer.help") {
        toolbarContent()
      }
  }

  @ToolbarContentBuilder
  private func toolbarContent() -> some CustomizableToolbarContent {
#if os(macOS)
    let placement: ToolbarItemPlacement? = nil
#else
    let placement: ToolbarItemPlacement = .bottomOrnament
#endif

#if os(macOS)
#else
    Action.toggleTOC(model).toolbarItem(.hidden, placement: placement)
#endif

    Action.navigation(model, placement: placement)
      .defaultCustomization(.hidden)

    //    ToolbarSpacer(.flexible, placement: .automatic)
    if model.kind == .document {
#if os(macOS)
      RendererToolbarPicker(docModel: model).toolbarItem
      TemplateToolbarPicker(docModel: model).toolbarItem
#else
#endif
      Action.reload(model).toolbarItem(.hidden, placement: placement)
    }

    Action.zoom(model.zoom, placement: placement)
      .defaultCustomization(.hidden)

#if os(macOS)
#else
    Action.find(model.find).toolbarItem(.hidden, placement: placement)

    ToolbarItem(id: "share", placement: placement) {
      ShareMenu(model: model)
    }

    ToolbarItem(id: "more", placement: placement) {
      MoreMenu(model: model)
    }
#endif

    //    ToolbarSpacer(.fixed, placement: .automatic)
  }

}

#if os(macOS)
/// Brings a toolbar `Menu` icon down to the visual size of sibling
/// toolbar buttons. SwiftUI hosts toolbar menus as `NSMenuToolbarItem`
/// at AppKit's larger metric, and font / imageScale / controlSize all
/// get dropped at the bridge — only `.scaleEffect` survives because it
/// runs at the SwiftUI compositor before AppKit sees the rendered
/// layer. Hit-testing keeps the original frame, which is fine.
/// This is only needed (0.8) for unifiedCompact toolbar style. .unified
/// style works correctly with scale set to 1.
private let toolbarMenuIconScale: CGFloat = 1.0

private struct RendererToolbarPicker: View {
  @Bindable var appModel = AppModel.shared
  @Bindable var docModel: DocumentModel

  var body: some View {
    processorMenu(
      appModel: appModel,
      documentModel: docModel)
    .scaleEffect(toolbarMenuIconScale, anchor: .center)
    .help("Markdown processor")
  }

  var toolbarItem: some CustomizableToolbarContent {
    ToolbarItem(id: "renderer", placement: .confirmationAction) {
      self
    }
    .defaultCustomization(.hidden)
  }
}

private struct TemplateToolbarPicker: View {
  @Bindable var appModel = AppModel.shared
  @Bindable var docModel: DocumentModel

  var body: some View {
    templateMenu(
      appModel: appModel,
      documentModel: docModel)
    .scaleEffect(toolbarMenuIconScale, anchor: .center)
    .help("Template")
  }

  var toolbarItem: some CustomizableToolbarContent {
    ToolbarItem(id: "template", placement: .confirmationAction) {
      self
    }
    .defaultCustomization(.hidden)
  }
}
#endif
