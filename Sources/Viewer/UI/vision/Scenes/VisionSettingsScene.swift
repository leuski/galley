//
//  VisionSettingsScene.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

#if os(visionOS)
import SwiftUI
import GalleyCoreKit

struct VisionSettingsScene: Scene {
  static let id = "settings"
  static let events = Set([OpenSettingsActivity.schemeExternalToken])
  @Environment(AppBoot.self) private var boot

  var body: some Scene {
    // Single settings window. visionOS has no `Settings { ... }`
    // scene type — instead we expose a regular `Window` reached via
    // `openWindow(id:)` from the document toolbar's gear button.
    // `restorationBehavior(.disabled)` keeps the window out of the
    // launch set: closing the app while Settings is open does not
    // bring it back on relaunch.
    Window("Settings", id: Self.id) {
      if let model = boot.model {
        VisionSettingsView(appModel: model)
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .windowResizability(.contentSize)
    .restorationBehavior(.disabled)
    .defaultSize(width: 640, height: 720)
    .handlesExternalEvents(matching: Self.events)
  }
}
#endif
