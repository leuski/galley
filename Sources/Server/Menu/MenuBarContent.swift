import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ALFoundation
import GalleyCoreKit
import GalleyServerKit

struct MenuBarContent: View {
  @Bindable var model: AppModel
  let server: PreviewServerController

  var body: some View {
    Group {
      statusItem

      Divider()

      TemplateMenu(model: model.templates)
      ProcessorMenu(model: model.processors)

      Divider()

      Button("Open File…") { openFile() }
        .accessibilityIdentifier(ServerA11yID.MenuBar.openFile)

      Divider()

      Button("Settings…") {
        NSWorkspace.shared.open(GalleyConstants.settingsURL)
      }
      .accessibilityIdentifier(ServerA11yID.MenuBar.settings)
    }
  }

  @ViewBuilder
  private var statusItem: some View {
    Group {
      switch server.state {
      case .running(let url):
        Text("Listening on \(url.hostAndPort)")
      case .stopped:
        Text("Server stopped")
      case .failed(let message):
        Text("Server error: \(message)")
      }
    }
    .accessibilityIdentifier(ServerA11yID.MenuBar.statusItem)
  }

  private func openFile() {
    let panel = NSOpenPanel()
    panel.identifier = .init(rawValue: "open.file.panel")
    panel.allowedContentTypes = MarkdownFileTypes.extensions
      .compactMap { ext in UTType(filenameExtension: ext) }
    + [ UTType.plainText ]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false

    guard
      panel.runModal() == .OK,
      let url = panel.url,
      let base = server.serverURL
    else { return }

    NSWorkspace.shared.open(base.appendingPreview(url))
  }
}
