//
//  TemplateModel.swift
//  GalleyKit
//
//  Created by Anton Leuski on 4/29/26.
//

import SwiftUI

extension Template: ChoiceValueProtocol {
  public typealias PersistentID = String
  public var persistentID: String { id }
}

public struct TemplateChoiceValue: ChoiceValueEnvelopeProtocol<Template> {
  nonisolated public let value: Value

  public init(_ value: Value) {
    self.value = value
  }
}

extension TemplateChoiceValue: SectionedChoiceValue {
  public var isAvailable: Bool { true }
  public var section: Int {
    switch self.value {
    case .builtIn: return 0
    case .userDefined: return 1
    }
  }
}

extension TemplateStore: ChoiceModelSource<Template> {
  public var values: [Template] { templates }
  public var defaultValue: Template { .default }
}

public typealias TemplateChoice = ConcreteChoiceModel<
  TemplateChoiceValue, TemplateStore>
