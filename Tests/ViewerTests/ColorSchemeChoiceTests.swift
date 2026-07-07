//
//  ColorSchemeChoiceTests.swift
//  Galley
//
//  Verifies that the static color-scheme catalog wires into the shared
//  `SelectableModel` infrastructure — i.e. that `ColorSchemePolicy`
//  satisfies `SelectablePolicy` with `Selection == Element ==
//  DocumentColorScheme`. This is what the
//  `SelectableModel<ColorSchemePolicy>` (`ColorSchemeChoice`) typealias
//  depends on; a regression here fails to compile, so the test doubles
//  as a conformance guard.
//

import Foundation
import GalleyCoreKit
import KosmosAppKit
import Testing
@testable import Galley

@MainActor
@Test("ColorSchemeChoice exposes both schemes and defaults to light")
func colorSchemeChoiceCatalog() {
  let choice = ColorSchemeChoice(initialSelection: nil)

  #expect(choice.elements.contains(.light))
  #expect(choice.elements.contains(.dark))
  #expect(choice.selected == .light)
}

@MainActor
@Test("ColorSchemeChoice hydrates a persisted dark selection")
func colorSchemeChoiceHydratesDark() {
  // Round-trip the persisted form through the policy's own encoder so
  // the test tracks the real serialization shape, not a hand-built one.
  let persisted = ColorSchemePolicy().encode(.dark)

  let choice = ColorSchemeChoice(initialSelection: persisted)

  #expect(choice.selected == .dark)
}
