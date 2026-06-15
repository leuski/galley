//
//  DcoumentScene.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

import SwiftUI
import GalleyCoreKit

struct DocumentScene: Scene {
  static let id = "document"
  static let events = Set([
    "file:", GalleyViewerRequestActivity.schemeExternalToken])

  var body: some Scene {
    // The document scene. SwiftUI materializes one `url == nil` member
    // at cold launch (WindowProbe FINDINGS §3) which `MacContentView`
    // uses as the invisible bootstrap anchor — capturing `openWindow`,
    // hosting `.onOpenURL`, and running the FTUE Open panel. No
    // separate welcome scene is needed.
    WindowGroup(id: Self.id, for: DocumentTarget.self) { $target in
#if os(macOS)
      MacContentView(target: $target)
#else
      VisionContentView(target: $target)
#endif
    }
    .handlesExternalEvents(matching: Self.events)
#if os(macOS)
    .defaultSize(width: 700, height: 900)
    .windowToolbarStyle(.unified)
    .commands { commands }
#else
    .windowResizability(.contentSize)
#endif
  }

#if os(macOS)
  @Bindable private var boot = AppBoot.shared
  @CommandsBuilder
  var commands: some Commands {
    FileCommands()
    EditCommands()
    ToolbarCommands()
    ViewCommands()
    if let model = boot.model {
      FormatCommands(appModel: model)
    }
    WindowCommands()
    HelpCommands()
  }
#endif
}
