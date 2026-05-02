//
//  Actions.swift
//  MarkdownPreviewer
//
//  Created by Anton Leuski on 4/30/26.
//

import SwiftUI

@MainActor
struct Action {
  let title: LocalizedStringResource
  let image: String
  let action: @MainActor (DocumentModel) -> Void
  let isEnabled: @MainActor (DocumentModel) -> Bool
  let shortcut: KeyboardShortcut?

  var helpLabel: String {
    let titleString = String(localized: title)
    guard let shortcut else { return titleString }
    return "\(titleString) (\(Self.format(shortcut)))"
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

  @ViewBuilder @MainActor
  func menuItem(model: DocumentModel?) -> some View {
    Button(title, systemImage: image) {
      guard let model else { return }
      action(model)
    }
    .disabled(!(model.map { isEnabled($0) } ?? false))
    .keyboardShortcut(shortcut)
  }

  @ViewBuilder @MainActor
  func toolbarItem(model: DocumentModel?) -> some View {
    Button(title, systemImage: image) {
      guard let model else { return }
      action(model)
    }
    .disabled(!(model.map { isEnabled($0) } ?? false))
    .help(helpLabel)
  }

  static let zoomIn = Action(
    title: "Zoom In",
    image: "plus.magnifyingglass",
    action: { $0.zoomIn() },
    isEnabled: { $0.canZoomOut },
    shortcut: .init("+", modifiers: [.command])
  )

  static let zoomOut = Action(
    title: "Zoom Out",
    image: "minus.magnifyingglass",
    action: { $0.zoomOut() },
    isEnabled: { $0.canZoomOut },
    shortcut: .init("-", modifiers: [.command])
  )

  static let resetZoom = Action(
    title: "Actual Size",
    image: "1.magnifyingglass",
    action: { $0.resetZoom() },
    isEnabled: { $0.canResetZoom },
    shortcut: .init("0", modifiers: [.command])
  )

  static let back = Action(
    title: "Back",
    image: "chevron.backward",
    action: { model in Task { await model.goBack() } },
    isEnabled: { $0.canGoBack },
    shortcut: .init("[", modifiers: [.command])
  )

  static let forward = Action(
    title: "Forward",
    image: "chevron.forward",
    action: { model in Task { await model.goForward() } },
    isEnabled: { $0.canGoForward },
    shortcut: .init("]", modifiers: [.command])
  )

  static let reload = Action(
    title: "Reload",
    image: "arrow.clockwise",
    action: { model in Task { await model.reload() } },
    isEnabled: { _ in true },
    shortcut: .init("r", modifiers: [.command])
  )
}
