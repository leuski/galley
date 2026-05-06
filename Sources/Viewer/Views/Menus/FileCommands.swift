import AppKit
import GalleyCoreKit
import SwiftUI

/// File menu — Open and Open Recent. SwiftUI's `WindowGroup` does not
/// install a system Open Recent menu (that's `NSDocument`-driven),
/// so we build it ourselves from `RecentDocumentsModel.urls`.
struct FileCommands: Commands {
  @Bindable var recents: RecentDocumentsModel
  @FocusedValue(\.documentModel) private var model
  @FocusedValue(\.viewerRenameContext) private var renameContext
  @FocusedValue(\.viewerExportPDFContext) private var exportPDFContext

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Open…", systemImage: "arrow.up.forward") {
        recents.presentOpenPanel()
      }
        .keyboardShortcut("o", modifiers: .command)
        .accessibilityIdentifier(ViewerA11yID.FileMenu.open)

      Menu("Open Recent", systemImage: "clock") {
        ForEach(recents.urls, id: \.self) { url in
          Button(url.lastPathComponent) {
            recents.openRecent(url)
          }
          .accessibilityIdentifier(
            "\(ViewerA11yID.FileMenu.openRecentItem).\(url.lastPathComponent)")
        }
        if !recents.urls.isEmpty {
          Divider()
        }
        Button("Clear Menu") { recents.clearAll() }
          .disabled(recents.urls.isEmpty)
          .accessibilityIdentifier(ViewerA11yID.FileMenu.openRecentClear)
      }
      .accessibilityIdentifier(ViewerA11yID.FileMenu.openRecentMenu)
    }

    CommandGroup(after: .saveItem) {
      Button("Rename…", systemImage: "pencil") {
        renameContext?.request()
      }
      .disabled(renameContext == nil)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.rename)

      Button("Open in Editor", systemImage: "arrow.up.forward.app") {
        guard let model else { return }
        Task { await model.openInEditor(line: nil) }
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(model == nil)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.openInEditor)

      Divider()

      Button("Export as PDF…", systemImage: "arrow.up.document") {
        exportPDFContext?.request()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(exportPDFContext == nil)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.exportPDF)
    }

    CommandGroup(replacing: .printItem) {
      Button("Page Setup…", systemImage: "text.page") {
        guard let model else { return }
        model.runPageSetup(on: NSApp.keyWindow)
      }
      .keyboardShortcut("p", modifiers: [.command, .shift])
      .disabled(model == nil)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.pageSetup)

      Button("Print…", systemImage: "printer") {
        guard let model else { return }
        let window = NSApp.keyWindow
        Task { await model.runPrintPanel(on: window) }
      }
      .keyboardShortcut("p", modifiers: .command)
      .disabled(model == nil)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.print)
    }
  }
}
