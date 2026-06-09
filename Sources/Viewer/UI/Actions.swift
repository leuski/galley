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
  static func zoomIn(_ model: DocumentModel?) -> Action {
    Action(
      title: "Zoom In",
      image: "plus.magnifyingglass",
      perform: { model?.zoomIn() },
      isEnabled: { model?.canZoomOut ?? false },
      shortcut: .init("+", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.zoomIn
    )
  }

  static func zoomOut(_ model: DocumentModel?) -> Action {
    Action(
      title: "Zoom Out",
      image: "minus.magnifyingglass",
      perform: { model?.zoomOut() },
      isEnabled: { model?.canZoomOut ?? false },
      shortcut: .init("-", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.zoomOut
    )
  }

  static func resetZoom(_ model: DocumentModel?) -> Action {
    Action(
      title: "Actual Size",
      image: "1.magnifyingglass",
      perform: { model?.resetZoom() },
      isEnabled: { model?.canResetZoom ?? false },
      shortcut: .init("0", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.actualSize
    )
  }

  static func back(_ model: DocumentModel?) -> Action {
    Action(
      title: "Back",
      image: "chevron.backward",
      perform: {
        guard let model else { return }
        Task { await model.goBack() }
      },
      isEnabled: { model?.canGoBack ?? false },
      shortcut: .init("[", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.back
    )
  }

  static func forward(_ model: DocumentModel?) -> Action {
    Action(
      title: "Forward",
      image: "chevron.forward",
      perform: {
        guard let model else { return }
        Task { await model.goForward() }
      },
      isEnabled: { model?.canGoForward ?? false },
      shortcut: .init("]", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.forward
    )
  }

  static func reload(_ model: DocumentModel?) -> Action {
    Action(
      title: "Reload",
      image: "arrow.clockwise",
      perform: {
        guard let model else { return }
        Task { await model.reload() }
      },
      shortcut: .init("r", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.reload
    )
  }

  /// Toolbar variant that flips the bar in and out, mirroring the
  /// show/hide affordance Safari and Preview surface in their
  /// toolbars. Title flips so the tooltip and accessibility label
  /// reflect the current state, just like `toggleTOC`.
  static func find(_ session: FindSession?) -> Action {
    Action(
      title: {
        (session?.isVisible ?? false) ? "Hide Find" : "Find…"
      },
      image: "magnifyingglass",
      perform: { env in
        session?.toggleFind(reduceMotion: env.reduceMotion)
      },
      shortcut: .init("f", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.find
    )
  }

  static func useSelectionForFind(_ session: FindSession?) -> Action {
    Action(
      title: "Use Selection for Find",
      image: "text.magnifyingglass",
      perform: { env in
        guard let session else { return }
        Task { await session
          .useSelectionForFind(reduceMotion: env.reduceMotion) }
      },
      shortcut: .init("e", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.useSelectionForFind
    )
  }

  static func findNext(_ model: SearchFieldModel?) -> Action {
    Action(
      title: "Find Next",
      image: "chevron.down",
      perform: {
        guard let model else { return }
        Task { await model.findNext() }
      },
      isEnabled: { (model?.matchCount ?? 0) > 0 },
      shortcut: .init("g", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.findNext
    )
  }

  static func findPrevious(_ model: SearchFieldModel?) -> Action {
    Action(
      title: "Find Previous",
      image: "chevron.up",
      perform: {
        guard let model else { return }
        Task { await model.findPrevious() }
      },
      isEnabled: { (model?.matchCount ?? 0) > 0 },
      shortcut: .init("g", modifiers: [.command, .shift]),
      accessibilityID: ViewerA11yID.ViewMenu.findPrevious
    )
  }

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
  /// `toolbarItem`). Title flips Show/Hide in the menu; the toolbar
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
}

#if os(macOS)
extension Action {
  static func showOnVisionPro(
    _ model: DocumentModel?,
    kosmos: ViewerKosmosService) -> Action
  {
    Action(
      title: { "Show on Vision Pro" },
      help: {
        kosmos.isAVPReachable
        ? "Open this document on the connected Vision Pro."
        : "No Vision Pro is currently paired with the bridge."
      },
      image: "visionpro",
      perform: { _ in
        model?.showOnVisionPro(kosmos: kosmos)
      },
      isEnabled: {
        kosmos.isAVPReachable
        && model?.documentURL.isFileURL == true
      },
      shortcut: .init("3", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.WindowMenu.showOnVisionPro
    )
  }
}
#endif
