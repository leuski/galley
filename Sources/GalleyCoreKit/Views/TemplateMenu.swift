import SwiftUI

public struct TemplateMenuContent<Model>: View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
  let title: String
  let model: Model

  public init(
    title: LocalizedStringResource? = nil, model: Model)
  {
    self.title = title.map { String(localized: $0) } ?? localized("Template")
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
