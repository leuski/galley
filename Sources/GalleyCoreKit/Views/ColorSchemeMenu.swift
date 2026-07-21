import SwiftUI

public struct ColorSchemeMenuContent<Model>: View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
  let title: String
  let model: Model

  public init(
    title: LocalizedStringResource? = nil, model: Model)
  {
    self.title = title.map { String(localized: $0) }
    ?? localized("Color Scheme")
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "circle.lefthalf.filled") {
      SelectableMenuCore(model: model)
    }
  }
}
