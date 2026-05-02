//
//  MarkdownPreviewerApp.swift
//  MarkdownPreviewer
//
//  Created by Anton Leuski on 4/25/26.
//

import SwiftUI
import GalleyCoreKit
import GalleyServerKit

@main
struct MarkdownPreviewerApp: App {
  @State private var boot = AppBoot()

  var body: some Scene {
    MenuBarExtra {
      if let model = boot.model {
        MenuBarContent(
          model: model,
          server: model.server)
      } else {
        Text("Starting…")
      }
    } label: {
      MenuBarLabel(state: boot.model?.server.state ?? .stopped)
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct MenuBarLabel: View {
  let state: PreviewServerController.State

  var body: some View {
    Image("MenuBarIcon")
  }

  private var tint: AnyShapeStyle {
    switch state {
    case .running: AnyShapeStyle(.primary)
    case .stopped: AnyShapeStyle(.secondary)
    case .failed: AnyShapeStyle(.red)
    }
  }
}
