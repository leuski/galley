import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ViewerApp: App {
  @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) var appDelegate
  @State private var boot = AppBoot()

  var body: some Scene {
    WindowGroup(for: URL.self) { $url in
      ContentView(fileURL: $url)
        .environment(boot)
        .environment(appDelegate)
    }
    .defaultSize(width: 700, height: 900)
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      FileCommands(delegate: appDelegate)
      ToolbarCommands()
      ViewCommands()
      if let model = boot.model {
        RenderingCommands(appModel: model)
      }
    }

    Settings {
      if let model = boot.model {
        SettingsView(appModel: model)
      } else {
        ProgressView("Starting…")
          .padding()
          .frame(minWidth: 320, minHeight: 200)
      }
    }
  }
}
