#if os(macOS)
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
      Action.toggleTOC(model).menuItem()
      Action.toggleStatusBar().menuItem()

      Divider()

      Action.zoomIn(model).menuItem()
      Action.zoomOut(model).menuItem()
      Action.resetZoom(model).menuItem()

      Divider()

      Action.back(model).menuItem()
      Action.forward(model).menuItem()
      Action.reload(model).menuItem()

      Divider()

    }
  }
}

struct WindowCommands: Commands {
  var kosmos: KosmosViewerService
  @FocusedValue(\.documentModel) private var model

  var body: some Commands {
    CommandGroup(before: .windowArrangement) {
      Action.showOnVisionPro(model, kosmos: kosmos).menuItem()
    }
  }
}
#endif
