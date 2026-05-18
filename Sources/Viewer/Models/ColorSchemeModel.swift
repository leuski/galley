//
//  ColorSchemeModel.swift
//  Galley
//
//  Created by Anton Leuski on 5/18/26.
//

import Foundation
import GalleyCoreKit
import Observation

struct ColorSchemeChoiceValue: ChoiceValueEnvelopeProtocol<DocumentColorScheme>
{
  nonisolated let value: Value

  init(_ value: Value) {
    self.value = value
  }

  /// Forward to the inner enum's localized name (Light / Dark) so
  /// catalog extraction picks them up — same pattern as
  /// `TemplateChoiceValue.name`.
  var name: LocalizedStringResource { value.localizedStringResource }
}

extension ColorSchemeChoiceValue: SectionedChoiceValue {
  var isAvailable: Bool { true }
  /// Single section — both cases are always available and there's no
  /// bundled-vs-user split. Returning a constant keeps `MenuCore`
  /// happy without surfacing a divider.
  var section: Int { 0 }
}

extension ColorSchemeChoiceValue: RestorableChoiceValue {
  typealias Source = ColorSchemeStore
}

/// Catalog of color-scheme options. Static — `DocumentColorScheme` is
/// a fixed two-case enum — but expressed through the same
/// `ChoiceModelSource` shape as `TemplateStore` / `ProcessorStore` so
/// the rest of the choice infrastructure (Scene envelopes,
/// `bindPersistent`) drops in unchanged.
@Observable @MainActor
final class ColorSchemeStore: ChoiceModelSource {
  static let shared = ColorSchemeStore()

  let values: [DocumentColorScheme] = DocumentColorScheme.allCases
  let defaultValue: DocumentColorScheme = .light
}

typealias ColorSchemeChoice = ConcreteChoiceModel<
  ColorSchemeChoiceValue, ColorSchemeStore>
