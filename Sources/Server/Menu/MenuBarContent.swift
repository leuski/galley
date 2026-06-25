import SwiftUI
import AppKit
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

      Button("Open Galley") { openGalley() }
        .accessibilityIdentifier(ServerA11yID.MenuBar.openGalley)

      Button("Open File…") { openFile() }
        .accessibilityIdentifier(ServerA11yID.MenuBar.openFile)

      Divider()

      Button("Settings…") {
        OpenSettingsActivity(.server).open()
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
          .accessibilityLabel("Server status: listening on \(url.hostAndPort)")
      case .stopped:
        Text("Server stopped")
          .accessibilityLabel("Server status: stopped")
      case .failed(let message):
        Text("Server error: \(message)")
          .accessibilityLabel("Server status: error, \(message)")
      }
    }
    .accessibilityIdentifier(ServerA11yID.MenuBar.statusItem)
  }

  /// Bring the Galley document app to the front, launching it first
  /// if it isn't running. Resolves the Viewer by its bundle id (which
  /// `GalleyConstants.suiteName` doubles as) so the Server doesn't
  /// hardcode a path.
  private func openGalley() {
    guard let appURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: GalleyConstants.suiteName)
    else { return }
    NSWorkspace.shared.openApplication(
      at: appURL,
      configuration: NSWorkspace.OpenConfiguration())
  }

  private func openFile() {
    let panel = NSOpenPanel()
    panel.identifier = .init(rawValue: "open.file.panel")
    panel.allowedContentTypes = MarkdownFileTypes.allTypesAndPlainText
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
