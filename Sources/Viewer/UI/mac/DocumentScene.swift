//
//  DcoumentScene.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

#if os(macOS)
import SwiftUI
import GalleyCoreKit

struct DocumentScene: Scene {
  static let id = "document"
  static let events = Set(["file:", "\(OpenDocumentActivity.scheme):"])
  @Environment(AppBoot.self) var boot: AppBoot

  var body: some Scene {
    // The document scene. SwiftUI materializes one `url == nil` member
    // at cold launch (WindowProbe FINDINGS §3) which `MacContentView`
    // uses as the invisible bootstrap anchor — capturing `openWindow`,
    // hosting `.onOpenURL`, and running the FTUE Open panel. No
    // separate welcome scene is needed.
    WindowGroup(id: Self.id, for: DocumentTarget.self) { $target in
      MacContentView(target: $target)
    }
    .handlesExternalEvents(matching: Self.events)
    .defaultSize(width: 700, height: 900)
    .windowToolbarStyle(.unified)
    .commands {
      FileCommands()
      EditCommands()
      ToolbarCommands()
      ViewCommands()
      if let model = boot.model {
        FormatCommands(appModel: model)
      }
      WindowCommands()
      HelpCommands()
      SettingsCommands()
    }
  }
}
#endif
