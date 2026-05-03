import SwiftUI

public struct TemplateMenu<Model>: View
where Model: ChoiceModel & AnyObject & Observable,
      Model.Element: SectionedChoiceValue
{
  let title: String
  let model: Model
  let action: @MainActor (String?) -> Void

  public init(
    title: String = "Template", model: Model,
    action: @escaping @MainActor (String?) -> Void)
  {
    self.title = title
    self.model = model
    self.action = action
  }

  public var body: some View {
    Menu(title, systemImage: "doc.richtext") {
      MenuPickerCore(model: model, action: action)
      Divider()
      Button("Reveal Templates Folder", systemImage: "folder") {
        TemplateStore.shared.revealFolder()
      }
    }
  }
}
