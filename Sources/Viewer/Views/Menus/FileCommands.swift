import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File menu — Open and Open Recent. SwiftUI's `WindowGroup` does not
/// install a system Open Recent menu (that's NSDocument's job), so we
/// build it ourselves from the delegate's observed list.
struct FileCommands: Commands {
  @Bindable var delegate: ViewerAppDelegate
  @FocusedValue(\.documentModel) private var model
  @FocusedValue(\.viewerRenameContext) private var renameContext

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Open…", systemImage: "arrow.up.forward") {
        delegate.presentOpenPanel()
      }
        .keyboardShortcut("o", modifiers: .command)

      Menu("Open Recent", systemImage: "clock") {
        ForEach(delegate.recentURLs, id: \.self) { url in
          Button(url.lastPathComponent) {
            delegate.openRecent(url)
          }
        }
        if !delegate.recentURLs.isEmpty {
          Divider()
        }
        Button("Clear Menu") { delegate.clearRecents() }
          .disabled(delegate.recentURLs.isEmpty)
      }
    }

    CommandGroup(after: .saveItem) {
      Button("Rename…", systemImage: "pencil") {
        guard let model, let context = renameContext, let url = context.url
        else { return }
        runRenamePopup(currentURL: url, model: model, context: context)
      }
      .disabled(renameContext?.url == nil)

      Button("Open in Editor", systemImage: "arrow.up.forward.app") {
        guard let model else { return }
        Task { await model.openInEditor(line: nil) }
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(model?.documentURL == nil)

      Divider()

      Button("Export as PDF…", systemImage: "arrow.up.document") {
        guard let model else { return }
        runExportPDFPanel(model: model)
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(model?.documentURL == nil)
    }

    CommandGroup(replacing: .printItem) {
      Button("Page Setup…", systemImage: "text.page") {
        guard let model else { return }
        model.runPageSetup(on: NSApp.keyWindow)
      }
      .keyboardShortcut("p", modifiers: [.command, .shift])
      .disabled(model?.documentURL == nil)

      Button("Print…", systemImage: "printer") {
        guard let model else { return }
        let window = NSApp.keyWindow
        Task { await model.runPrintPanel(on: window) }
      }
      .keyboardShortcut("p", modifiers: .command)
      .disabled(model?.documentURL == nil)
    }
  }
}

@MainActor
private func runRenamePopup(
  currentURL: URL,
  model: DocumentModel,
  context: RenameContext
) {
  let alert = NSAlert()
  alert.messageText = "Rename Document"
  alert.informativeText = "Enter a new file name for this document."
  alert.alertStyle = .informational
  alert.addButton(withTitle: "Rename")
  alert.addButton(withTitle: "Cancel")

  let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
  field.stringValue = currentURL.lastPathComponent
  field.placeholderString = currentURL.lastPathComponent
  alert.accessoryView = field
  alert.window.initialFirstResponder = field

  guard alert.runModal() == .alertFirstButtonReturn else { return }
  let newName = field.stringValue
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !newName.isEmpty, newName != currentURL.lastPathComponent
  else { return }

  Task { @MainActor in
    do {
      let newURL = try await model.renameCurrentDocument(toName: newName)
      context.apply(newURL)
    } catch {
      NSSound.beep()
    }
  }
}

/// Run a save panel and export the rendered document to PDF. Engages
/// print-media CSS in `DocumentModel.exportPDF` so template `@page`
/// rules style page breaks and margins.
@MainActor
private func runExportPDFPanel(model: DocumentModel) {
  guard let url = model.documentURL else { return }

  let panel = NSSavePanel()
  panel.title = "Export as PDF"
  panel.allowedContentTypes = [.pdf]
  panel.nameFieldStringValue =
    url.deletingPathExtension().lastPathComponent + ".pdf"
  panel.directoryURL = url.deletingLastPathComponent()

  guard panel.runModal() == .OK, let destination = panel.url else { return }

  let window = NSApp.keyWindow
  Task { @MainActor in
    do {
      try await model.exportPDF(to: destination, on: window)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Couldn’t export PDF"
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .warning
      alert.runModal()
    }
  }
}
