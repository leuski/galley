import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ALFoundation
import GalleyCoreKit
import GalleyServerKit

struct MenuBarContent: View {
  let model: AppModel
  let server: PreviewServerController
  let templateStore: TemplateStore
  @Bindable var templates: TemplateChoice

  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Group {
      statusItem

      Divider()

      templatesMenu
      rendererMenu

      Divider()

      Button("Open File…") { openFile() }

      Divider()

      Button("Settings…") {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      }

      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }

  @ViewBuilder
  private var statusItem: some View {
    switch server.state {
    case .running(let url):
      Text("Listening on \(url.hostAndPort)")
    case .stopped:
      Text("Server stopped")
    case .failed(let message):
      Text("Server error: \(message)")
    }
  }

  @ViewBuilder
  private var templatesMenu: some View {
    Menu("Template") {
      MenuCore(model: templates)
      Divider()
      Button("Reveal Templates Folder") {
        templateStore.revealFolder()
      }
    }
  }

  @ViewBuilder
  private var rendererMenu: some View {
    Menu("Processor") {
      MenuCore(model: model.processors)
    }
  }

  private func openFile() {
    let panel = NSOpenPanel()
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

    NSWorkspace.shared.open(base.appendingPreviewPath(url.path))
  }
}
