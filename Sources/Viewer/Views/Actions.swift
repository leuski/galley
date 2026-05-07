//
//  Actions.swift
//  Galley
//
//  Created by Anton Leuski on 4/30/26.
//

import GalleyCoreKit
import SwiftUI

@MainActor
struct Action {
  let title: @MainActor (DocumentModel?) -> LocalizedStringResource
  let image: String
  /// The action receives the live `reduceMotion` env so toggles that
  /// animate (e.g. sidebar reveal) can honor accessibility settings
  /// from any call site without each call site re-implementing the
  /// check.
  let action: @MainActor (DocumentModel, _ reduceMotion: Bool) -> Void
  let isEnabled: @MainActor (DocumentModel) -> Bool
  let shortcut: KeyboardShortcut?
  let accessibilityID: String

  init(
    title: @escaping @MainActor (DocumentModel?) -> LocalizedStringResource,
    image: String,
    action: @escaping @MainActor (DocumentModel, _ reduceMotion: Bool) -> Void,
    isEnabled: @escaping @MainActor (DocumentModel) -> Bool,
    shortcut: KeyboardShortcut?,
    accessibilityID: String
  ) {
    self.title = title
    self.image = image
    self.action = action
    self.isEnabled = isEnabled
    self.shortcut = shortcut
    self.accessibilityID = accessibilityID
  }

  init(
    title: LocalizedStringResource,
    image: String,
    action: @escaping @MainActor (DocumentModel, _ reduceMotion: Bool) -> Void,
    isEnabled: @escaping @MainActor (DocumentModel) -> Bool,
    shortcut: KeyboardShortcut?,
    accessibilityID: String
  ) {
    self.init(
      title: { _ in title },
      image: image,
      action: action,
      isEnabled: isEnabled,
      shortcut: shortcut,
      accessibilityID: accessibilityID
    )
  }

  init(
    title: LocalizedStringResource,
    image: String,
    action: @escaping @MainActor (DocumentModel) -> Void,
    isEnabled: @escaping @MainActor (DocumentModel) -> Bool,
    shortcut: KeyboardShortcut?,
    accessibilityID: String
  ) {
    self.init(
      title: { _ in title },
      image: image,
      action: { model, _ in action(model) },
      isEnabled: isEnabled,
      shortcut: shortcut,
      accessibilityID: accessibilityID
    )
  }

  func helpLabel(_ model: DocumentModel?) -> LocalizedStringResource {
    let title = self.title(model)
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

  func menuItem(model: DocumentModel?) -> some View {
    ActionMenuButton(action: self, model: model)
  }

  func toolbarItem(model: DocumentModel?) -> some View {
    ActionToolbarButton(action: self, model: model)
  }

  static let zoomIn = Action(
    title: "Zoom In",
    image: "plus.magnifyingglass",
    action: { $0.zoomIn() },
    isEnabled: { $0.canZoomOut },
    shortcut: .init("+", modifiers: [.command]),
    accessibilityID: ViewerA11yID.ViewMenu.zoomIn
  )

  static let zoomOut = Action(
    title: "Zoom Out",
    image: "minus.magnifyingglass",
    action: { $0.zoomOut() },
    isEnabled: { $0.canZoomOut },
    shortcut: .init("-", modifiers: [.command]),
    accessibilityID: ViewerA11yID.ViewMenu.zoomOut
  )

  static let resetZoom = Action(
    title: "Actual Size",
    image: "1.magnifyingglass",
    action: { $0.resetZoom() },
    isEnabled: { $0.canResetZoom },
    shortcut: .init("0", modifiers: [.command]),
    accessibilityID: ViewerA11yID.ViewMenu.actualSize
  )

  static let back = Action(
    title: "Back",
    image: "chevron.backward",
    action: { model in Task { await model.goBack() } },
    isEnabled: { $0.canGoBack },
    shortcut: .init("[", modifiers: [.command]),
    accessibilityID: ViewerA11yID.ViewMenu.back
  )

  static let forward = Action(
    title: "Forward",
    image: "chevron.forward",
    action: { model in Task { await model.goForward() } },
    isEnabled: { $0.canGoForward },
    shortcut: .init("]", modifiers: [.command]),
    accessibilityID: ViewerA11yID.ViewMenu.forward
  )

  static let reload = Action(
    title: "Reload",
    image: "arrow.clockwise",
    action: { model in Task { await model.reload() } },
    isEnabled: { _ in true },
    shortcut: .init("r", modifiers: [.command]),
    accessibilityID: ViewerA11yID.ViewMenu.reload
  )

  /// Sidebar / Table-of-Contents toggle. Single source of truth shared
  /// by the View menu (via `menuItem`) and the document toolbar (via
  /// `toolbarItem`). Title flips Show/Hide in the menu; the toolbar
  /// uses the static "Toggle…" label as its tooltip / accessibility
  /// label.
  static let toggleTOC = Action(
    title: { model in
      (model?.showsTOC ?? false)
        ? "Hide Table of Contents"
        : "Show Table of Contents"
    },
    image: "sidebar.left",
    action: { model, reduceMotion in
      if reduceMotion {
        model.showsTOC.toggle()
      } else {
        withAnimation { model.showsTOC.toggle() }
      }
    },
    isEnabled: { _ in true },
    shortcut: .init("1", modifiers: [.command, .control]),
    accessibilityID: ViewerA11yID.ViewMenu.toggleTOC
  )
}

/// Menu rendering for an `Action`. Dedicated View so `@Environment` for
/// reduce-motion can be threaded into the action closure without each
/// call site repeating the env wiring.
@MainActor
private struct ActionMenuButton: View {
  let action: Action
  let model: DocumentModel?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action.title(model), systemImage: action.image) {
      guard let model else { return }
      action.action(model, reduceMotion)
    }
    .disabled(!(model.map { action.isEnabled($0) } ?? false))
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
  let model: DocumentModel?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action.title(model), systemImage: action.image) {
      guard let model else { return }
      action.action(model, reduceMotion)
    }
    .disabled(!(model.map { action.isEnabled($0) } ?? false))
    .help(action.helpLabel(model))
    .accessibilityLabel(Text(action.title(model)))
    .accessibilityIdentifier(action.accessibilityID)
  }
}
