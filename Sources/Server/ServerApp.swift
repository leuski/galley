//
//  GalleyApp.swift
//  Galley
//
//  Created by Anton Leuski on 4/25/26.
//

import SwiftUI

@main
struct ServerApp: App {
  @State private var boot = AppBoot()
  @NSApplicationDelegateAdaptor private var appDelegate: ServerAppDelegate

  var body: some Scene {
    MenuBarExtra {
      if let model = boot.model {
        MenuBarContent(
          model: model,
          server: model.server)
          .onAppear { appDelegate.boot = boot }
      } else {
        Text("Starting…")
          .onAppear { appDelegate.boot = boot }
      }
    } label: {
      Image("MenuBarIcon")
    }
    .menuBarExtraStyle(.menu)
  }
}
