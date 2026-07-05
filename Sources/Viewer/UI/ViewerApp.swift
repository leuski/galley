import GalleyCoreKit
import SwiftUI

@main
struct ViewerApp: App {
  @Environment(\.openWindow) var openWindow
  @Environment(\.scenePhase) var scenePhase
  @State var appModel = AppModel.shared

  var body: some Scene {
    DocumentScene()
      .environment(appModel)
#if os(visionOS)
      .onChange(of: scenePhase, handlePhaseChange(
        openWindow, appModel: appModel))
#endif

    HelpScene()
      .environment(appModel)
#if os(visionOS)
      .onChange(of: scenePhase, handlePhaseChange(
        openWindow, appModel: appModel))
#endif

    SettingsScene()
      .environment(appModel)
  }
}
