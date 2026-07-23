import SwiftUI

public struct TemplateMenuContent<Model>: View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
  let title: LocalizedStringResource
  let model: Model

  public init(
    title: LocalizedStringResource, model: Model)
  {
    self.title = title
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "doc.richtext") {
      SelectableMenuCore(model: model)
#if os(macOS)
      Divider()
      Button(
        localized("Reveal Templates Folder"),
        systemImage: "folder") {
          TemplateStore.shared.revealFolder()
        }
#endif
    }
  }
}
