//
//  DocumentScene.swift
//  Galley
//

import SwiftUI
import GalleyCoreKit

/// The document window group, shared by macOS and visionOS.
///
/// The `WindowGroup` value type is `DocumentSceneID` — a minted UUID, so
/// SwiftUI hands the content view a non-nil id for every window (via
/// `defaultValue:`) and persists/restores it. There is no nil-value
/// bootstrap member; the document a window shows is resolved from
/// `DocumentStore` by id (restored) or arrives via `onOpenURL` (remote).
struct DocumentScene: Scene {
  static let id = "document"
  static let events = Set([
    "file:", GalleyViewerRequestActivity.schemeExternalToken])

  var body: some Scene {
    // Optional value (no `defaultValue:`). The `defaultValue:` variant
    // force-unwraps the restored binding, which TRAPS when SwiftUI
    // restores a window whose persisted value can't decode as a
    // `DocumentSceneID` (e.g. saved state from a build that used a
    // different value type, or corrupt state) — a launch crash before
    // any of our code runs. With the optional variant an undecodable
    // value is simply `nil`, and `DocumentSceneContent` mints a fresh id.
    WindowGroup(id: Self.id, for: DocumentSceneID.self) { $sceneID in
      DocumentSceneContent(sceneID: sceneID)
    } defaultValue: {
      DocumentSceneID.next()
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
  private var appModel: AppModel { AppModel.shared }

  @CommandsBuilder
  var commands: some Commands {
    SettingsCommands()
    FileCommands()
    EditCommands()
    ToolbarCommands()
    ViewCommands()
    FormatCommands(appModel: appModel)
    WindowCommands()
    HelpCommands()
  }
#endif
}
