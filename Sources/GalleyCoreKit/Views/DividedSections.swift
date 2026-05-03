//
//  DividedSections.swift
//  GalleyKit
//
//  Created by Anton Leuski on 4/29/26.
//

import SwiftUI

/// Renders an array of arrays as a single ForEach with `Divider()`
/// between non-empty sections. Used to group built-in and
/// user-installed renderers in the menu.
public struct DividedSections<Item, ID, Content: View>: View
where ID: Hashable
{
  public init(
    sections: [[Item]],
    id: KeyPath<Item, ID>,
    @ViewBuilder content: @escaping (Item) -> Content)
  {
    self.sections = sections
    self.id = id
    self.content = content
  }

  let sections: [[Item]]
  let id: KeyPath<Item, ID>
  @ViewBuilder let content: (Item) -> Content

  public var body: some View {
    let nonEmpty = sections.filter { !$0.isEmpty }
    ForEach(Array(nonEmpty.enumerated()), id: \.offset) { index, section in
      if index > 0 { Divider() }
      ForEach(section, id: id) { content($0) }
    }
  }
}

public struct DividedPicker<Item, ID, Content: View, SelectedValue>: View
where ID: Hashable, SelectedValue: Hashable
{
  public init(
    sections: [[Item]],
    selection: Binding<SelectedValue>,
    id: KeyPath<Item, ID>,
    @ViewBuilder content: @escaping (Item) -> Content)
  {
    self.sections = sections
    self.selection = selection
    self.id = id
    self.content = content
  }

  let sections: [[Item]]
  let selection: Binding<SelectedValue>
  let id: KeyPath<Item, ID>
  @ViewBuilder let content: (Item) -> Content

  public var body: some View {
    Picker(selection: selection) {
      DividedSections(sections: sections, id: id, content: content)
    } label: { EmptyView() }
      .pickerStyle(.inline)
  }
}

public struct MenuCore<Model>: View
where Model: ChoiceModel, Model.Element: SectionedChoiceValue
{
  let model: Model

  public init(model: Model) {
    self.model = model
  }

  public var body: some View {
    let values = model.values
      .reduce(into: [:]) { result, value in
        result[value.section, default: []].append(value)
      }
      .sorted { $0.key < $1.key }
      .map { $0.value }
    DividedSections(sections: values, id: \.self) { value in
      Toggle(value.name, isOn: model.isSelectedBinding(value))
        .disabled(!value.isAvailable)
    }
  }
}
