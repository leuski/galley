import SwiftUI
import AppKit

public enum PullDownEntry {
  case item(String, () -> Void)
  case separator
}

/// SwiftUI `Button` that opens a native `NSMenu` on press.
///
/// The menu is anchored to a sibling `NSView` captured via `.background`.
/// `NSMenu.popUp(positioning:at:in:)` is invoked the moment the button
/// transitions into its pressed state — that's what lets the menu's
/// tracking loop pick up the click-and-hold-and-drag-to-select gesture
/// instead of only opening on click release.
public struct PullDownIconButton: View {
  let systemImage: String
  let accessibilityLabel: LocalizedStringResource
  let entries: () -> [PullDownEntry]

  @State private var anchor = MenuAnchor()

  public init(
    systemImage: String,
    accessibilityLabel: LocalizedStringResource,
    entries: @escaping () -> [PullDownEntry])
  {
    self.systemImage = systemImage
    self.accessibilityLabel = accessibilityLabel
    self.entries = entries
  }

  public var body: some View {
    Button(action: showMenu) {
      HStack(spacing: 3) {
        Image(systemName: systemImage)
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .font(.caption2.weight(.semibold))
      }
    }
    .accessibilityLabel(accessibilityLabel)
    .background(MenuAnchorView(anchor: anchor))
  }

  @MainActor
  private func showMenu() {
    let menu = buildMenu()
    if let view = anchor.view, view.window != nil {
      let origin = NSPoint(x: 0, y: -4)
      menu.popUp(positioning: nil, at: origin, in: view)
    } else {
      // Fallback: anchor in screen coords at the cursor. Used when the
      // .background NSView didn't make it into a real window — e.g., some
      // toolbar render paths don't install background representables.
      menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    for entry in entries() {
      switch entry {
      case .separator:
        menu.addItem(.separator())
      case .item(let title, let action):
        let target = MenuTarget(action: action)
        let item = NSMenuItem(
          title: title,
          action: #selector(MenuTarget.run(_:)),
          keyEquivalent: "")
        item.target = target
        item.representedObject = target  // retain target for menu lifetime
        menu.addItem(item)
      }
    }
    return menu
  }
}

@MainActor
private final class MenuAnchor {
  weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
  let anchor: MenuAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if anchor.view !== nsView { anchor.view = nsView }
  }
}

private final class MenuTarget: NSObject {
  let action: () -> Void
  init(action: @escaping () -> Void) { self.action = action }
  @objc func run(_ sender: Any?) { action() }
}
