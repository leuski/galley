//
//  ProcessorModel.swift
//  GalleyKit
//

import SwiftUI

public typealias ProcessorPolicy = SelectableStorePolicy<ProcessorStore>
public extension ProcessorPolicy {
  init() {
    self.init(store: .shared)
  }
}

public typealias ProcessorChoice = SelectableModel<ProcessorPolicy>

extension ProcessorChoice {
  public convenience init(
    initialSelection: PersistentSelectionRepresentation? = nil,
    notifier: Notifier? = nil)
  {
    self.init(
      source: ProcessorPolicy(),
      initialSelection: initialSelection,
      notifier: notifier)
  }
}

extension Processor: SectionedChoiceValue {
  public var section: Int { isBuiltIn ? 0 : 1 }
}
