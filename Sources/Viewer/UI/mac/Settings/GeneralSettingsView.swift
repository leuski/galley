#if os(macOS)
import SwiftUI
import GalleyCoreKit

struct GeneralSettingsView: View {
  @Bindable var defaults = Defaults.shared

  var body: some View {
    openDocumentPicker
    ReadingSpeedStepper(spacing: 4)
  }

  @ViewBuilder
  private var openDocumentPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Open document")
        Spacer()
        OpenBehaviorPicker(selection: $defaults.openBehavior)
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
      Toggle(
        "Tint window with page background",
        isOn: $defaults.tintWindowWithPageBackground)
      Text("""
            Paints the page background color behind the window \
            toolbar and sidebar. When the template does not declare a \
            background color, the default system color is used.
            """
      )
      .subtitle()
    }
  }
}

#Preview {
  GeneralSettingsView()
}
#endif
