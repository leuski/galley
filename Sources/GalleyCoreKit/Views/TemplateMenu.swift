import SwiftUI

public struct TemplateMenuContent<Model>: View
where Model: ChoiceModel & AnyObject & Observable,
      Model.Element: SectionedChoiceValue
{
  let title: LocalizedStringResource
  let model: Model

  public init(
    title: LocalizedStringResource? = nil, model: Model)
  {
    self.title = title ?? LocalizedStringResource(
      "Template", bundle: .galleyCoreKit)
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "doc.richtext") {
      MenuCore(model: model)
#if os(macOS)
      Divider()
      Button(
        LocalizedStringResource(
          "Reveal Templates Folder", bundle: .galleyCoreKit),
        systemImage: "folder") {
          TemplateStore.shared.revealFolder()
        }
#endif
    }
  }
}
