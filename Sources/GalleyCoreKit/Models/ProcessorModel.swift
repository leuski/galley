//
//  ProcessorModel.swift
//  GalleyKit
//

import SwiftUI

extension Processor: ChoiceValueProtocol {
  public typealias PersistentID = String
  public var persistentID: String { id }
}

public struct ProcessorChoiceValue: ChoiceValueEnvelopeProtocol<Processor> {
  nonisolated public let value: Value

  public init(_ value: Value) {
    self.value = value
  }
}

extension ProcessorChoiceValue: SectionedChoiceValue {
  public var isAvailable: Bool { value.isAvailable }
  public var section: Int {
    value.isBuiltIn ? 0 : 1
  }
}

extension ProcessorStore: ChoiceModelSource<Processor> {
  public var values: [Processor] { processors }
  public var defaultValue: Processor { .builtIn }
}

public typealias ProcessorChoice = ConcreteChoiceModel<
  ProcessorChoiceValue, ProcessorStore>
