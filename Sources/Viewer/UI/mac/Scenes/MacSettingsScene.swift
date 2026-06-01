//
//  MacSettingsScene.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

#if os(macOS)
import SwiftUI
import GalleyCoreKit

struct MacSettingsScene: Scene {
  static let id = "settings"
  static let events = Set(["\(OpenSettingsActivity.scheme):"])
  @Environment(AppBoot.self) var boot: AppBoot

  var body: some Scene {
    Window("Settings", id: Self.id) {
      if let model = boot.model {
        MacSettingsView(appModel: model)
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .windowToolbarStyle(.unified)
    .handlesExternalEvents(matching: Self.events)
    .restorationBehavior(.disabled)
    .commandsRemoved()
    .windowResizability(.contentSize)
    .windowIdealSize(.fitToContent)
  }
}
#endif
