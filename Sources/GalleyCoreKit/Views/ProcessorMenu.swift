import SwiftUI

public struct ProcessorMenuContent<Model>: View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
  let title: LocalizedStringResource
  let model: Model

  public init(title: LocalizedStringResource, model: Model) {
    self.title = title
    self.model = model
  }

  public var body: some View {
    Menu(title, systemImage: "wand.and.stars") {
      SelectableMenuCore(model: model)
      Divider()
      Button(
        localized("Rescan Installed Processors"),
        systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
          ProcessorStore.shared.rediscover()
        }
    }
  }
}
