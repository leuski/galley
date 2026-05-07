//
//  TemplateModel.swift
//  GalleyKit
//
//  Created by Anton Leuski on 4/29/26.
//

import Foundation

public struct TemplateChoiceValue: ChoiceValueEnvelopeProtocol<Template> {
  nonisolated public let value: Value

  public init(_ value: Value) {
    self.value = value
  }

  /// Override the envelope's default `name` (which would wrap the
  /// inner value's `description` as a runtime `LocalizationValue`,
  /// losing catalog extraction) and forward to `Template.name` so
  /// the bundled "Default" lands in the catalog and user-defined
  /// templates stay out of it.
  public var name: LocalizedStringResource { value.name }
}

extension TemplateChoiceValue: SectionedChoiceValue {
  public var isAvailable: Bool { true }
  /// Section by source index — bundled templates and user templates
  /// render in distinct menu groups. Production has 0 = bundle and
  /// 1 = user; future sources (e.g. team-shared dirs) get their own
  /// sections automatically.
  public var section: Int { value.sourceIndex }
}

extension TemplateChoiceValue: RestorableChoiceValue {
  public typealias Source = TemplateStore
}

extension TemplateStore: ChoiceModelSource<Template> {
  public var values: [Template] { templates }
  public var defaultValue: Template {
    existingTemplate(forID: "\(Self.bundleSourceIndex).Default")
      ?? .bundledDefault
  }
}

public typealias TemplateChoice = ConcreteChoiceModel<
  TemplateChoiceValue, TemplateStore>
