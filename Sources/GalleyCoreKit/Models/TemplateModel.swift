//
//  TemplateModel.swift
//  GalleyKit
//
//  Created by Anton Leuski on 4/29/26.
//

import Foundation

public struct TemplatePolicy: SelectablePolicy<Template> {
  public typealias PersistentSelectionRepresentation = NamedPair<Template.ID>
  public typealias Selection = Template

  private let store: TemplateStore
  public var elements: [Template] { store.templates }
  public var defaultSelection: Template { .bundledDefault }
  public func decode(_ value: PersistentSelectionRepresentation) -> Selection? {
    store.existingTemplate(forID: value.id)
  }
  public func encode(_ value: Selection) -> PersistentSelectionRepresentation {
    .init(id: value.id, name: String(localized: value.name))
  }
  public func contains(_ value: Selection) -> Bool {
    store.existingTemplate(forID: value.id) != nil
  }
  public init(_ store: TemplateStore = .shared) {
    self.store = store
  }
}

public typealias TemplateChoice = SelectableModel<TemplatePolicy>

extension TemplateChoice {
  public convenience init(
    initialSelection: PersistentSelectionRepresentation? = nil,
    notifier: Notifier? = nil)
  {
    self.init(
      source: TemplatePolicy(),
      initialSelection: initialSelection,
      notifier: notifier)
  }
}

extension Template: SectionedChoiceValue {
  public var section: Int { sourceIndex }
}
