import GalleyCoreKit
import SwiftUI
import KosmosAppKit

@main
struct ViewerApp: App {
  init() {
    // Touching the singleton here builds it (and runs `warmCache`) at app
    // launch, before any scene body — it *is* the boot point now.
    _ = AppModel.shared
  }

  var body: some Scene {
    DocumentScene()
#if os(visionOS)
      .handlePhaseChange()
#endif

    HelpScene()
#if os(visionOS)
      .handlePhaseChange()
#endif

    SettingsScene()
  }
}
