import SwiftUI

public struct TemplateMenuContent<Model>: View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
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
      SelectableMenuCore(model: model)
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
