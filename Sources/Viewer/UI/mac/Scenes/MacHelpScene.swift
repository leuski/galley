//
//  MacHelpScene.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

#if os(macOS)
import SwiftUI
import GalleyCoreKit

struct MacHelpScene: Scene {
  static let id = "help"
  static let events = Set(["\(OpenHelpActivity.scheme):"])

  var body: some Scene {
    // Singleton Help window. It claims the `galley-help://` scheme via
    // `handlesExternalEvents`, so firing `galley-help://<bundle-path>`
    // at the app opens/raises it and delivers the URL to
    // `HelpWindowView.onOpenURL`. `openModel` + `recents` are injected
    // because the child `DocumentView` reads them.
    // `.restorationBehavior(.disabled)` keeps help out of state
    // restoration — closing the app while help is open doesn't bring it
    // back on relaunch.
    Window("Help", id: Self.id) {
      HelpWindowView()
    }
    .handlesExternalEvents(matching: Self.events)
    .restorationBehavior(.disabled)
    // Drop SwiftUI's static "Help" entry from the Window menu —
    // AppKit auto-lists the window dynamically once it's visible
    // (and removes the entry when it closes), so the static entry
    // would only show "Help" as an always-present opener even when
    // no help window exists.
    .commandsRemoved()
    .defaultSize(width: 600, height: 900)
  }
}
#endif
