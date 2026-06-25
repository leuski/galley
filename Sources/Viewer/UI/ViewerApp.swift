import GalleyCoreKit
import SwiftUI

@main
struct ViewerApp: App {
  @Environment(\.openWindow) var openWindow
  @Environment(\.scenePhase) var scenePhase

  init() {
    // Touching the singleton here builds it (and runs `warmCache`) at app
    // launch, before any scene body — it *is* the boot point now.
    _ = AppModel.shared
  }

  var body: some Scene {
    DocumentScene()
#if os(visionOS)
      .onChange(of: scenePhase, handlePhaseChange(openWindow))
#endif

    HelpScene()
#if os(visionOS)
      .onChange(of: scenePhase, handlePhaseChange(openWindow))
#endif

    SettingsScene()
  }
}
