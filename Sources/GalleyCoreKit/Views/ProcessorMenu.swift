import SwiftUI

public struct ProcessorMenu<Model>: View
where Model: ChoiceModel & AnyObject & Observable,
      Model.Element: SectionedChoiceValue
{
  let title: LocalizedStringResource
  let model: Model

  public init(
    title: LocalizedStringResource? = nil, model: Model)
  {
    self.title = title ?? LocalizedStringResource(
      "Processor", bundle: .galleyCoreKit)
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "wand.and.stars") {
      MenuCore(model: model)
      Divider()
      Button(
        LocalizedStringResource(
          "Rescan Installed Processors", bundle: .galleyCoreKit),
        systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
          ProcessorStore.shared.rediscover()
        }
    }
  }
}
