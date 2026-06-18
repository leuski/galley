#if os(macOS)
import AppKit
import GalleyCoreKit
import SwiftUI

/// File menu — Open and Open Recent. SwiftUI's `WindowGroup` does not
/// install a system Open Recent menu (that's `NSDocument`-driven),
/// so we build it ourselves from `RecentDocumentsModel.urls`.
struct FileCommands: Commands {
  @FocusedValue(\.documentModel) private var model
  @Bindable var recents = AppModel.shared.recents

  var visibleWindows: [NSWindow] {
    NSApp.windows.filter { window in
      window.isVisible
    }
  }

  var frontWindow: NSWindow? {
    NSApp.mainWindow ?? NSApp.keyWindow ?? visibleWindows.first
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Open…", systemImage: "arrow.up.forward") {
        AppModel.shared.recents.presentOpenPanel()
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

    // Replace the `.saveItem` slot — which is otherwise empty for us —
    // with explicit Close / Close All commands at a stable position
    // below Open. SwiftUI's auto-injected Close pair lands above
    // `.newItem` whenever the singleton Help window participates in
    // the multi-window state, which puts it above our Open — a
    // visual bug rooted in SwiftUI's File-menu rebuild quirks. Owning
    // the commands ourselves keeps the order predictable regardless
    // of which scene is key.
    CommandGroup(replacing: .saveItem) {
      Button("Close", systemImage: "xmark") {
        frontWindow?.performClose(nil)
      }
      .disabled(frontWindow == nil)
      .keyboardShortcut("w", modifiers: .command)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.close)

      Button("Close All", systemImage: "xmark.rectangle") {
        // Iterate over a snapshot; `performClose(_:)` mutates
        // `NSApp.windows` as the close animation completes. Filter
        // out invisible / excluded windows (the Welcome anchor sits
        // at alpha 0 and is excluded; we don't want to ask it to
        // close).
        for window in visibleWindows {
          window.performClose(nil)
        }
      }
      .disabled(visibleWindows.isEmpty)
      .keyboardShortcut("w", modifiers: [.command, .option])
      .accessibilityIdentifier(ViewerA11yID.FileMenu.closeAll)
    }

    CommandGroup(after: .saveItem) {
      Button("Rename…", systemImage: "pencil") {
        model?.requestRename()
      }
      .disabled(model?.isRegular != true
                || model?.documentURL.isFileURL != true)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.rename)

      Button("Open in Editor", systemImage: "arrow.up.forward.app") {
        guard let model else { return }
        Task { await model.openInEditor(line: nil) }
      }
      .keyboardShortcut("e", modifiers: [.command, .option])
      .disabled(model == nil || model?.documentURL.isFileURL != true)
      .accessibilityIdentifier(ViewerA11yID.FileMenu.openInEditor)

      Divider()

      Button("Export as PDF…", systemImage: "arrow.up.document") {
        model?.requestExportPDF()
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(model == nil)
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
#endif
