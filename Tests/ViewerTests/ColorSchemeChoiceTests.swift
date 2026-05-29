//
//  ColorSchemeChoiceTests.swift
//  Galley
//
//  Verifies that the static color-scheme catalog wires into the
//  shared `Choice` infrastructure — i.e. that `ColorSchemeStore`
//  satisfies `ChoiceModelSource` and `ColorSchemeChoiceValue`
//  satisfies the envelope/restorable contracts. This is what the
//  `ConcreteChoiceModel<ColorSchemeChoiceValue, ColorSchemeStore>`
//  typealias depends on; a regression here fails to compile, so the
//  test doubles as a conformance guard.
//

import Foundation
import GalleyCoreKit
import KosmosAppKit
import Testing
@testable import Galley

@MainActor
@Test("ColorSchemeChoice exposes both schemes and defaults to light")
func colorSchemeChoiceCatalog() {
  let choice = ColorSchemeChoice(
    source: ColorSchemeStore.shared, persistent: nil)

  let schemes = choice.values.map(\.value)
  #expect(schemes.contains(.light))
  #expect(schemes.contains(.dark))
  #expect(choice.selected.value == .light)
}

@MainActor
@Test("ColorSchemeChoice hydrates a persisted dark selection")
func colorSchemeChoiceHydratesDark() throws {
  let dark = ColorSchemeChoiceValue(.dark)
  let persisted = try #require(dark.persist())

  let choice = ColorSchemeChoice(
    source: ColorSchemeStore.shared, persistent: persisted)

  #expect(choice.selected.value == .dark)
}
