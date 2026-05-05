import SwiftUI
import GalleyCoreKit

struct GeneralSettingsView: View {
  @Bindable var defaults = Defaults.shared

  var body: some View {
    Section {
      openDocumentPicker
    }
  }

  @ViewBuilder
  private var openDocumentPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Open document")
        Spacer()
        Picker(selection: $defaults.openBehavior) {
          ForEach(OpenBehavior.allCases) { behavior in
            Text(behavior.displayName).tag(behavior)
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      Text("""
            Applies when opening files via Finder, the Open dialog, or \
            Open Recent. With no existing window, a new window is \
            always used.
            """
      )
      .subtitle()
    }
  }
}

#Preview {
  GeneralSettingsView()
}
