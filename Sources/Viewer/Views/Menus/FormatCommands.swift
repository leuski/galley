import GalleyCoreKit
import SwiftUI

/// Format menu — exposes the renderer (markdown processor) and
/// template pickers as menu items so users can switch globally
/// without opening a settings window.
///
/// When `AppModel.enablePerDocumentOverrides` is on, the same
/// menus drive the frontmost window's per-document choice; the
/// `.global` value at the top of each list represents "Use Global
/// Setting." When the flag is off, the menus drive the global
/// selection directly.
struct FormatCommands: Commands {
  @Bindable var appModel: AppModel
  @FocusedValue(\.documentModel) private var documentModel

  var body: some Commands {
    CommandMenu("Format") {
      // Subscribe to per-window selections so this body re-evaluates
      // and the system menu rebuilds when an override flips. NSMenu
      // doesn't pick up internal Toggle invalidations on its own.
      templateMenu(
        title: "Template",
        globalTitle: "Global Template",
        appModel: appModel,
        documentModel: documentModel)

      processorMenu(
        title: "Markdown Processor",
        globalTitle: "Global Markdown Processor",
        appModel: appModel,
        documentModel: documentModel)
    }
  }
}
