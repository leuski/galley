import SwiftUI
import AppKit
import GalleyCoreKit

struct MenuBarContent: View {
  @Bindable var model: AppModel

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
        .disabled(model.httpURL == nil)

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
      if !model.httpFeatureAvailable {
        Text("HTTP preview off — Quick Look renders in-process")
          .accessibilityLabel("Server status: HTTP preview unavailable")
      } else {
        switch model.httpState {
        case .running(let url):
          Text("Listening on \(url.hostAndPort)")
            .accessibilityLabel(
              "Server status: listening on \(url.hostAndPort)")
        case .stopped:
          Text("Server stopped")
            .accessibilityLabel("Server status: stopped")
        case .failed(let message):
          Text("Server error: \(message)")
            .accessibilityLabel("Server status: error, \(message)")
        }
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
      let base = model.httpURL
    else { return }

    NSWorkspace.shared.open(base.appendingPreview(url))
  }
}
