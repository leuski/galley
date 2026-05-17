import SwiftUI
import GalleyCoreKit

struct GeneralSettingsView: View {
  @Bindable var defaults = Defaults.shared

  var body: some View {
    Section {
      openDocumentPicker
      statusBarSettings
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

    VStack(alignment: .leading, spacing: 4) {
      Toggle("Transparent toolbar", isOn: $defaults.transparentToolbar)
      Text("""
            Uses the template background color to paint the window \
            toolbar and sidebar background. If the template does not \
            have background color specified, we use the default OS color.
            """
      )
      .subtitle()
    }
  }

  @ViewBuilder
  private var statusBarSettings: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent("Reading speed") {
        Stepper(
          value: $defaults.readingWordsPerMinute,
          in: 50...600,
          step: 10
        ) {
          Text("\(defaults.readingWordsPerMinute) wpm")
            .monospacedDigit()
        }
      }
      Text("""
            Words per minute used to estimate reading time in the \
            status bar.
            """
      )
      .subtitle()
    }
  }
}

#Preview {
  GeneralSettingsView()
}
