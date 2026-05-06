//
//  TemplateModel.swift
//  GalleyKit
//
//  Created by Anton Leuski on 4/29/26.
//

import Foundation

extension Template: ChoiceValueProtocol {
  public typealias PersistentID = String
  public var persistentID: String { id }
}

public struct TemplateChoiceValue: ChoiceValueEnvelopeProtocol<Template> {
  nonisolated public let value: Value

  public init(_ value: Value) {
    self.value = value
  }

  /// Override the envelope's default `name` (which would wrap the
  /// inner value's `description` as a runtime `LocalizationValue`,
  /// losing catalog extraction) and forward to `Template.name` so
  /// `BuiltInTemplate`'s literal "Default" lands in the catalog and
  /// user-defined templates stay out of it.
  public var name: LocalizedStringResource { value.name }
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

extension TemplateChoiceValue: RestorableChoiceValue {
  public typealias Source = TemplateStore
}

extension TemplateStore: ChoiceModelSource<Template> {
  public var values: [Template] { templates }
  public var defaultValue: Template { .default }
}

public typealias TemplateChoice = ConcreteChoiceModel<
  TemplateChoiceValue, TemplateStore>
