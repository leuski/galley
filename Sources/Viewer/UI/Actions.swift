//
//  Actions.swift
//  Galley
//
//  Created by Anton Leuski on 4/30/26.
//

import GalleyCoreKit
import KosmosAppKit
import SwiftUI

// MARK: - DocumentModel factories

extension Action {

  /// Status-bar toggle. Flips the global `showsStatusBar` default,
  /// since the bar is a chrome preference rather than per-document
  /// state. Every open window observes the change through SwiftUI's
  /// `@ObservableDefaults` pipeline.
  static func toggleStatusBar() -> Action {
    Action(
      title: {
        Defaults.shared.showsStatusBar
        ? "Hide Status Bar"
        : "Show Status Bar"
      },
      image: "ruler",
      perform: { env in
        withAnimationAsNeeded(env.reduceMotion) {
          Defaults.shared.showsStatusBar.toggle()
        }
      },
      shortcut: .init("2", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.ViewMenu.toggleStatusBar
    )
  }

  /// Sidebar / Table-of-Contents toggle. Single source of truth shared
  /// by the View menu (via `menuItem`) and the document toolbar (via
  /// `toolbarButton`). Title flips Show/Hide in the menu; the toolbar
  /// uses the static "Toggle…" label as its tooltip / accessibility
  /// label.
  static func toggleTOC(_ model: DocumentModel?) -> Action {
    Action(
      title: {
        (model?.showsTOC ?? false)
        ? "Hide Table of Contents"
        : "Show Table of Contents"
      },
      image: "sidebar.left",
      perform: { env in
        guard let model else { return }
        model.toggleTOC(reduceMotion: env.reduceMotion)
      },
      shortcut: .init("1", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.ViewMenu.toggleTOC
    )
  }

  static func howToMakeTemplate() -> Action {
    let url = Bundle.main.url(
      forResource: "template-authoring",
      withExtension: "md")

    return Action(
      title: "How to Make a Template",
      image: "questionmark.circle",
      perform: { _ in
        guard let url else { return }
        OpenHelpActivity(documentURL: url).open()
      },
      isEnabled: { url != nil },
      accessibilityID: ViewerA11yID.HelpMenu.templateAuthoring
    )
  }

  static func settings() -> Action {
    Action(
      title: "Settings…",
      image: "gearshape",
      perform: { _ in
        OpenSettingsActivity().open()
      },
      accessibilityID: ViewerA11yID.ToolbarSettings.settings
    )
  }

  static func open() -> Action {
    Action(
      title: "Open…",
      image: "arrow.up.forward",
      perform: { _ in
#if os(macOS)
        AppModel.shared.recents.presentOpenPanel()
#endif
      },
      shortcut: .init("o", modifiers: [.command]),
      accessibilityID: ViewerA11yID.FileMenu.open
    )
  }

  
}

#if os(macOS)
extension Action {
  static func showOnVisionPro(_ model: DocumentModel?) -> Action
  {
    Action(
      title: { "Show on Vision Pro" },
      help: {
        AppModel.shared.kosmos.isAVPReachable
        ? "Open this document on the connected Vision Pro."
        : "No Vision Pro is currently paired with the bridge."
      },
      image: "visionpro",
      perform: { _ in
        model?.showOnVisionPro(kosmos: AppModel.shared.kosmos)
      },
      isEnabled: {
        AppModel.shared.kosmos.isAVPReachable
        && model?.documentURL.isFileURL == true
      },
      shortcut: .init("3", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.WindowMenu.showOnVisionPro
    )
  }
}
#endif
