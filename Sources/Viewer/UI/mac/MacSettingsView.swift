#if os(macOS)
import GalleyCoreKit
import SwiftUI

struct MacSettingsView: View {
  @Bindable var appModel: AppModel

  var body: some View {
    TabView(selection: $appModel.selectedSettingsTab) {
      GeneralSettingsView()
        .settingsPane()
        .tabItem {
          Label("General", systemImage: "gearshape")
        }
        .tag(SettingsTab.general)

      MarkdownSettingsView(appModel: appModel)
        .settingsPane()
        .tabItem {
          Label("Markdown", systemImage: "doc.text")
        }
        .tag(SettingsTab.markdown)

      ServerSettingsView()
        .settingsPane()
        .tabItem {
          Label("Server", systemImage: "server.rack")
        }
        .tag(SettingsTab.server)
    }
    .frame(width: 620, height: 320)
    // The Settings scene claims `galley-settings://` via
    // `handlesExternalEvents` (see `MacViewerApp`); a deep-linked
    // `?tab=<id>` arrives here and selects the pane.
    .onOpenURL { url in
      guard let activity = OpenSettingsActivity(from: url) else {
        return
      }
      if let tab = activity.tab {
        appModel.selectedSettingsTab = tab
      }
    }
  }
}

struct SettingsPaneModifier: ViewModifier {
  func body(content: Content) -> some View {
    Form {
      content
    }
    .formStyle(.grouped)
  }
}

extension View {
  func settingsPane() -> some View {
    modifier(SettingsPaneModifier())
  }
}

#Preview {
  MacSettingsView(appModel: AppModel())
}
#endif
