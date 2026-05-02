import SwiftUI

public struct ProcessorMenu<Model>: View
where Model: ChoiceModel, Model.Element: SectionedChoiceValue
{
  let title: String
  let model: Model

  public init(title: String = "Processor", model: Model) {
    self.title = title
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "wand.and.stars") {
      MenuCore(model: model)
      Divider()
      Button(
        "Rescan Installed Processors",
        systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
      {
        ProcessorStore.shared.rediscover()
      }
    }
  }
}
