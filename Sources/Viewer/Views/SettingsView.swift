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
    .frame(minHeight: 360)
  }
}

struct SettingsPaneModifier: ViewModifier {
  func body(content: Content) -> some View {
    Form{
      content
    }
    .padding()
    .formStyle(.grouped)
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
