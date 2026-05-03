import SwiftUI

public struct ProcessorMenu<Model>: View
where Model: ChoiceModel & AnyObject & Observable,
      Model.Element: SectionedChoiceValue
{
  let title: String
  let model: Model
  let action: @MainActor (String?) -> Void

  public init(
    title: String = "Processor", model: Model,
    action: @escaping @MainActor (String?) -> Void)
  {
    self.title = title
    self.model = model
    self.action = action
  }

  public var body: some View {
    Menu(title, systemImage: "wand.and.stars") {
      MenuPickerCore(model: model, action: action)
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
