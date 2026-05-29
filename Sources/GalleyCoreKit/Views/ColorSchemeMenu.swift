import SwiftUI
import KosmosAppKit

public struct ColorSchemeMenu<Model>: View
where Model: ChoiceModel & AnyObject & Observable,
      Model.Element: SectionedChoiceValue
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
      MenuCore(model: model)
    }
  }
}
