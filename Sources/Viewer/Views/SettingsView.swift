import SwiftUI

struct SettingsView: View {
  @Bindable var appModel: AppModel

  var body: some View {
    TabView {
      GeneralSettingsView()
        .settingsPane()
        .tabItem {
          Label("General", systemImage: "gearshape")
        }

      MarkdownSettingsView(appModel: appModel)
        .settingsPane()
        .tabItem {
          Label("Markdown", systemImage: "doc.text")
        }

      ServerSettingsView()
        .settingsPane()
        .tabItem {
          Label("Server", systemImage: "server.rack")
        }
    }
    .frame(minWidth: 580, maxWidth: 580, minHeight: 360)
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
