import SwiftUI

public struct ColorSchemeMenuContent<Model>: View
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
      "Color Scheme", bundle: .galleyCoreKit)
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "circle.lefthalf.filled") {
      SelectableMenuCore(model: model)
    }
  }
}
