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
  @Environment(AppBoot.self) var boot: AppBoot

  var body: some Scene {
    Window("Settings", id: Self.id) {
      if let model = boot.model {
#if os(macOS)
        MacSettingsView(appModel: model)
#else
        VisionSettingsView(appModel: model)
#endif
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
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
