import SwiftUI

public struct TemplateMenu<Model>: View
where Model: ChoiceModel & AnyObject & Observable,
      Model.Element: SectionedChoiceValue
{
  let title: String
  let model: Model

  public init(
    title: String = "Template", model: Model)
  {
    self.title = title
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "doc.richtext") {
      MenuCore(model: model)
      Divider()
      Button("Reveal Templates Folder", systemImage: "folder") {
        TemplateStore.shared.revealFolder()
      }
    }
  }
}
