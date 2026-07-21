import SwiftUI

public struct ProcessorMenuContent<Model>: View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
  let title: String
  let model: Model

  public init(
    title: LocalizedStringResource? = nil, model: Model)
  {
    self.title = title.map { String(localized: $0) } ?? localized("Processor")
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
