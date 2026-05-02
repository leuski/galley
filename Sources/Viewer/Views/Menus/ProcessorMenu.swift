import GalleyCoreKit
import SwiftUI

struct ProcessorMenu: View {
  let localTitle: String
  let globalTitle: String
  @Bindable var appModel: AppModel
  let processors: SceneProcessorChoice?

  init(
    title: String = "Processor",
    globalTitle: String? = nil,
    appModel: AppModel,
    choices processors: SceneProcessorChoice? = nil)
  {
    self.localTitle = title
    self.globalTitle = globalTitle ?? title
    self.appModel = appModel
    self.processors = processors
  }

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
