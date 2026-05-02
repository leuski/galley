import GalleyCoreKit
import SwiftUI

struct ProcessorMenu: View {
  let localTitle: String
  let globalTitle: String
  @Bindable var appModel: AppModel
  let processors: SceneProcessorChoice?

  var title: String {
    appModel.enablePerDocumentOverrides && processors != nil
    ? localTitle : globalTitle
  }

  var body: some View {
    Menu(title, systemImage: "wand.and.stars") {
      if appModel.enablePerDocumentOverrides, let processors {
        MenuCore(model: processors)
      } else {
        MenuCore(model: appModel.processors)
      }
      Divider()
      Button(
        "Rescan Installed Processors",
        systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
      {
        Task { await appModel.rediscoverRenderers() }
      }
    }
  }
}
