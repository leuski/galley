import SwiftUI

@MainActor
public func colorSchemeMenuContent<Model>(
  title: LocalizedStringResource, model: Model) -> some View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
  Menu(title, systemImage: "circle.lefthalf.filled") {
    SelectableMenuCore(model: model)
  }
}

@MainActor
public func processorMenuContent<Model>(
  title: LocalizedStringResource, model: Model) -> some View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
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

@MainActor
public func templateMenuContent<Model>(
  title: LocalizedStringResource, model: Model) -> some View
where Model: Selectable,
      Model.Element == Model.Selection,
      Model.Element: SectionedChoiceValue & Identifiable
{
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
