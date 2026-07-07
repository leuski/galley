//
//  ProcessorModel.swift
//  GalleyKit
//

import SwiftUI

public struct ProcessorPolicy: SelectablePolicy<Processor> {
  public typealias PersistentSelectionRepresentation = NamedPair<Processor.ID>
  public typealias Selection = Processor

  private let store: ProcessorStore
  public var elements: [Processor] { store.processors }
  public var defaultSelection: Processor { .builtIn }
  public var isReady: Bool { store.isReady }
  public func decode(_ value: PersistentSelectionRepresentation) -> Selection? {
    store.existingProcessor(forID: value.id)
  }
  public func encode(_ value: Selection) -> PersistentSelectionRepresentation {
    .init(id: value.id, name: String(localized: value.name))
  }
  public func contains(_ value: Selection) -> Bool {
    store.existingProcessor(forID: value.id) != nil
  }
  public init(_ store: ProcessorStore = .shared) {
    self.store = store
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
