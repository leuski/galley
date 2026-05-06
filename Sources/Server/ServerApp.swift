//
//  GalleyApp.swift
//  Galley
//
//  Created by Anton Leuski on 4/25/26.
//

import SwiftUI
import GalleyCoreKit
import GalleyServerKit

@main
struct ServerApp: App {
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
      Image("MenuBarIcon")
    }
    .menuBarExtraStyle(.menu)
  }
}
