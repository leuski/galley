//
//  Actions.swift
//  Galley
//
//  Created by Anton Leuski on 4/30/26.
//

import GalleyCoreKit
import SwiftUI

/// Bound action — title/icon/shortcut metadata plus closures that
/// already capture whichever model they act on. `Action` itself is
/// model-agnostic: the menu and toolbar renderers know nothing about
/// `DocumentModel` or any future model type. Factories live as static
/// methods (e.g. `Action.zoomIn(_:)`) so a single file lists every
/// action the app ships, while still letting each factory bind to a
/// specific model type via its parameter.
@MainActor
struct Action {
  let title: @MainActor () -> LocalizedStringResource
  let image: String
  /// The action receives the live `reduceMotion` env so toggles that
  /// animate (e.g. sidebar reveal) can honor accessibility settings
  /// from any call site without each call site re-implementing the
  /// check.
  let perform: @MainActor (_ reduceMotion: Bool) -> Void
  let isEnabled: @MainActor () -> Bool
  let shortcut: KeyboardShortcut?
  let accessibilityID: String

  init(
    title: @escaping @MainActor () -> LocalizedStringResource,
    image: String,
    perform: @escaping @MainActor (_ reduceMotion: Bool) -> Void,
    isEnabled: @escaping @MainActor () -> Bool = { true },
    shortcut: KeyboardShortcut? = nil,
    accessibilityID: String
  ) {
    self.title = title
    self.image = image
    self.perform = perform
    self.isEnabled = isEnabled
    self.shortcut = shortcut
    self.accessibilityID = accessibilityID
  }

  init(
    title: LocalizedStringResource,
    image: String,
    perform: @escaping @MainActor (_ reduceMotion: Bool) -> Void,
    isEnabled: @escaping @MainActor () -> Bool = { true },
    shortcut: KeyboardShortcut? = nil,
    accessibilityID: String
  ) {
    self.init(
      title: { title },
      image: image,
      perform: perform,
      isEnabled: isEnabled,
      shortcut: shortcut,
      accessibilityID: accessibilityID
    )
  }

  init(
    title: LocalizedStringResource,
    image: String,
    perform: @escaping @MainActor () -> Void,
    isEnabled: @escaping @MainActor () -> Bool = { true },
    shortcut: KeyboardShortcut? = nil,
    accessibilityID: String
  ) {
    self.init(
      title: { title },
      image: image,
      perform: { _ in perform() },
      isEnabled: isEnabled,
      shortcut: shortcut,
      accessibilityID: accessibilityID
    )
  }

  func helpLabel() -> LocalizedStringResource {
    let title = self.title()
    guard let shortcut else { return title }
    return "\(title) (\(Self.format(shortcut)))"
  }

  // Standard macOS glyph order: ⌃⌥⇧⌘ then key.
  private static func format(_ shortcut: KeyboardShortcut) -> String {
    var out = ""
    if shortcut.modifiers.contains(.control) { out += "⌃" }
    if shortcut.modifiers.contains(.option)  { out += "⌥" }
    if shortcut.modifiers.contains(.shift)   { out += "⇧" }
    if shortcut.modifiers.contains(.command) { out += "⌘" }
    out.append(glyph(for: shortcut.key))
    return out
  }

  private static func glyph(for key: KeyEquivalent) -> String {
    switch key {
    case .return:        return "↩"
    case .tab:           return "⇥"
    case .space:         return "␣"
    case .delete:        return "⌫"
    case .escape:        return "⎋"
    case .leftArrow:     return "←"
    case .rightArrow:    return "→"
    case .upArrow:       return "↑"
    case .downArrow:     return "↓"
    default:             return String(key.character).uppercased()
    }
  }

  func menuItem() -> some View {
    ActionMenuButton(action: self)
  }

  func toolbarItem(imageOnly: Bool = false) -> some View {
    ActionToolbarButton(action: self, imageOnly: imageOnly)
  }
}

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
      perform: { reduceMotion in
        session?.toggleFind(reduceMotion: reduceMotion)
      },
      shortcut: .init("f", modifiers: [.command]),
      accessibilityID: ViewerA11yID.ViewMenu.find
    )
  }

  static func useSelectionForFind(_ session: FindSession?) -> Action {
    Action(
      title: "Use Selection for Find",
      image: "text.magnifyingglass",
      perform: { reduceMotion in
        guard let session else { return }
        Task { await session.useSelectionForFind(reduceMotion: reduceMotion) }
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
      perform: { reduceMotion in
        withAnimationAsNeeded(reduceMotion) {
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
      perform: { reduceMotion in
        guard let model else { return }
        model.toggleTOC(reduceMotion: reduceMotion)
      },
      shortcut: .init("1", modifiers: [.command, .control]),
      accessibilityID: ViewerA11yID.ViewMenu.toggleTOC
    )
  }
}

/// Menu rendering for an `Action`. Dedicated View so `@Environment` for
/// reduce-motion can be threaded into the action closure without each
/// call site repeating the env wiring.
@MainActor
private struct ActionMenuButton: View {
  let action: Action
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action.title(), systemImage: action.image) {
      action.perform(reduceMotion)
    }
    .disabled(!action.isEnabled())
    .keyboardShortcut(action.shortcut)
    .accessibilityIdentifier(action.accessibilityID)
  }
}

/// Toolbar rendering for an `Action`. Toolbar buttons keep the static
/// `title` for tooltip/accessibility — flipping a tooltip with state
/// looks erratic next to the static icon.
@MainActor
private struct ActionToolbarButton: View {
  let action: Action
  let imageOnly: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      action.perform(reduceMotion)
    } label: {
      if imageOnly {
        Image(systemName: action.image)
      } else {
        Label(action.title(), systemImage: action.image)
      }
    }
    .disabled(!action.isEnabled())
    .help(action.helpLabel())
    .accessibilityLabel(action.title())
    .accessibilityIdentifier(action.accessibilityID)
  }
}
