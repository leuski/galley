//
//  SettingsScene.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

import SwiftUI
import GalleyCoreKit

struct SettingsScene: Scene {
  static let id = "settings"
  static let events = Set([OpenSettingsActivity.schemeExternalToken])
  private var model: AppModel { AppModel.shared }

  var body: some Scene {
    Window("Settings", id: Self.id) {
#if os(macOS)
      MacSettingsView(appModel: model)
#else
      VisionSettingsView(appModel: model)
#endif
    }
    .handlesExternalEvents(matching: Self.events)
    .windowResizability(.contentSize)
    .restorationBehavior(.disabled)
#if os(macOS)
    .windowToolbarStyle(.unified)
    .commandsRemoved()
    .windowIdealSize(.fitToContent)
#else
    .defaultSize(width: 640, height: 720)
#endif
  }
}
