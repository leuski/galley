//
//  TemplateModel.swift
//  GalleyKit
//
//  Created by Anton Leuski on 4/29/26.
//

import Foundation

public typealias TemplatePolicy = SelectableStorePolicy<TemplateStore>
public extension TemplatePolicy {
  init() {
    self.init(store: .shared)
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
