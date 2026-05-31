#if os(macOS)
import GalleyCoreKit
import SwiftUI

struct SettingsView: View {
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
    .frame(minWidth: 520, minHeight: 320)
    // The Settings scene claims `galley-settings://` via
    // `handlesExternalEvents` (see `MacViewerApp`); a deep-linked
    // `?tab=<id>` arrives here and selects the pane.
    .onOpenURL { url in
      if case .openSettings(let tab) = url.galleyRequest, let tab {
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
    .padding()
  }
}

extension View {
  func settingsPane() -> some View {
    modifier(SettingsPaneModifier())
  }
}

#Preview {
  SettingsView(appModel: AppModel())
}
#endif
