import GalleyCoreKit
import SwiftUI

struct TemplateMenu: View {
  let localTitle: String
  let globalTitle: String
  @Bindable var appModel: AppModel
  let templates: SceneTemplateChoice?

  var title: String {
    appModel.enablePerDocumentOverrides && templates != nil
    ? localTitle : globalTitle
  }

  var body: some View {
    Menu(title, systemImage: "doc.richtext") {
      if appModel.enablePerDocumentOverrides, let templates {
        MenuCore(model: templates)
      } else {
        MenuCore(model: appModel.templates)
      }
      Divider()
      Button("Reveal Templates Folder", systemImage: "folder") {
        appModel.revealTemplatesFolder()
      }
    }
  }
}
