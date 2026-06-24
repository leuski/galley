#if os(macOS)
import GalleyCoreKit
import SwiftUI

/// File menu — Open and Open Recent. SwiftUI's `WindowGroup` does not
/// install a system Open Recent menu (that's `NSDocument`-driven),
/// so we build it ourselves from `RecentDocumentsModel.urls`.
struct FileCommands: Commands {
  @FocusedValue(\.documentModel) private var model

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Action.open(isPresented: nil).menuItem()
        .modifier(OpenFileModifier(isPresented: nil))
      Action.openRecentMenu()
    }

    // Replace the `.saveItem` slot — which is otherwise empty for us —
    // with explicit Close / Close All commands at a stable position
    // below Open. SwiftUI's auto-injected Close pair lands above
    // `.newItem` whenever the singleton Help window participates in
    // the multi-window state, which puts it above our Open — a
    // visual bug rooted in SwiftUI's File-menu rebuild quirks. Owning
    // the commands ourselves keeps the order predictable regardless
    // of which scene is key.
    CommandGroup(replacing: .saveItem) {
      Action.close().menuItem()
      Action.closeAll().menuItem()
    }

    CommandGroup(after: .saveItem) {
      Action.rename(model).menuItem()
      Action.openInEditor(model).menuItem()

      Divider()

      Action.exportPDF(model).menuItem()
    }

    CommandGroup(replacing: .printItem) {
      Action.pageSetup(model).menuItem()
      Action.print(model).menuItem()
    }
  }
}
#endif
