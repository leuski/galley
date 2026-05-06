import AppKit
import GalleyCoreKit
import SwiftUI

/// Menu items that mirror the toolbar's navigation buttons. Lives in
/// the View menu (replacing the system-provided sidebar group, which
/// the Viewer doesn't use).
struct ViewCommands: Commands {
  @FocusedValue(\.documentModel) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

  /// The TOC sidebar toggle. Rendered as a `Button` whose title flips
  /// between "Show" and "Hide" — the standard macOS show/hide pattern
  /// (matches Finder's "Show Sidebar" / "Hide Sidebar" affordance).
  /// When no document window is focused, falls back to a disabled
  /// "Show…" so the keyboard shortcut still appears in the menu.
  @ViewBuilder
  private var tocToggle: some View {
    let title = (model?.showsTOC ?? false)
      ? "Hide Table of Contents"
      : "Show Table of Contents"
    Button {
      guard let model else { return }
      if reduceMotion {
        model.showsTOC.toggle()
      } else {
        withAnimation { model.showsTOC.toggle() }
      }
    } label: {
      Label(title, systemImage: "sidebar.left")
    }
    .disabled(model == nil)
    .keyboardShortcut("1", modifiers: [.command, .control])
    .accessibilityIdentifier(ViewerA11yID.ViewMenu.toggleTOC)
  }
}
