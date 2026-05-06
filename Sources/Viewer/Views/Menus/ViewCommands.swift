import AppKit
import GalleyCoreKit
import SwiftUI

/// Menu items that mirror the toolbar's navigation buttons. Lives in
/// the View menu (replacing the system-provided sidebar group, which
/// the Viewer doesn't use).
struct ViewCommands: Commands {
  @FocusedValue(\.documentModel) private var model

  var body: some Commands {
    CommandGroup(before: .toolbar) {
      tocToggle

      Divider()

      Action.zoomIn.menuItem(model: model)
      Action.zoomOut.menuItem(model: model)
      Action.resetZoom.menuItem(model: model)

      Divider()

      Action.back.menuItem(model: model)
      Action.forward.menuItem(model: model)
      Action.reload.menuItem(model: model)

      Divider()
    }
  }

  /// The TOC sidebar toggle. Rendered as a `Toggle` so the menu shows
  /// a checkmark while the sidebar is on. When no document window is
  /// focused, falls back to a disabled placeholder so the keyboard
  /// shortcut still appears in the menu.
  @ViewBuilder
  private var tocToggle: some View {
    if let model {
      Toggle(isOn: Binding(
        get: { model.showsTOC },
        set: { model.showsTOC = $0 }
      )) {
        Label("Table of Contents", systemImage: "sidebar.left")
      }
      .keyboardShortcut("1", modifiers: [.command, .control])
      .accessibilityIdentifier(ViewerA11yID.ViewMenu.toggleTOC)
    } else {
      Toggle(isOn: .constant(false)) {
        Label("Table of Contents", systemImage: "sidebar.left")
      }
      .disabled(true)
      .keyboardShortcut("1", modifiers: [.command, .control])
      .accessibilityIdentifier(ViewerA11yID.ViewMenu.toggleTOC)
    }
  }
}
