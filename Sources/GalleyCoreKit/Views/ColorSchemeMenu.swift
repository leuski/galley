import SwiftUI

public struct ColorSchemeMenuContent<Model>: View
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
    Menu(title, systemImage: "circle.lefthalf.filled") {
      SelectableMenuCore(model: model)
    }
  }
}
