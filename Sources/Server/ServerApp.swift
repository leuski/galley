//
//  GalleyApp.swift
//  Galley
//
//  Created by Anton Leuski on 4/25/26.
//

import SwiftUI

@main
struct ServerApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: ServerAppDelegate

  init() {
    _ = AppModel.shared
  }

  var body: some Scene {
#if DEBUG
    MenuBarExtra {
      Button("Quit Galley Server") {
        NSApplication.shared.terminate(nil)
      }
      .accessibilityIdentifier("quit")
    } label: {
      Image("MenuBarIcon")
    }
    .menuBarExtraStyle(.menu)
#else
    // Release: faceless. `LSUIElement` (Info.plist) plus a dormant
    // `Settings` scene means no Dock icon and no menu-bar item — the
    // bridge runs headless, and LaunchServices cold-launches it on
    // demand for dot-bridge:// / Services / App Intent triggers.
    Settings {
      EmptyView()
    }
#endif
  }
}
