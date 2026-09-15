//
//  MenuPolicyTests.swift
//  Galley
//
//  Guards the routing rule behind the toolbar / Format-menu template,
//  processor, and color-scheme pickers: when per-document overrides are
//  OFF the menu must drive the *global* choice (what the render path
//  reads), never the window-local one. Regression: the shared
//  `menuPolicy` once returned the local model regardless of the flag,
//  so every pick landed on an ignored per-window override and the
//  document never changed.
//

import Foundation
import GalleyCoreKit
import KosmosAppKit
import Testing
@testable import Galley

@MainActor
@Test("Overrides off: menu drives the global choice, not the local one")
func menuPolicyUsesGlobalWhenOverridesOff() {
  let global = ColorSchemeChoice(initialSelection: nil)
  let local = ColorSchemeChoice(initialSelection: nil)

  let (_, resolvedLocal, resolvedGlobal) = menuPolicy(
    appModel: global,
    documentModel: local,
    localTitle: "Local",
    globalTitle: "Global",
    overridesEnabled: false)

  #expect(resolvedLocal == nil)
  #expect(resolvedGlobal === global)
}

@MainActor
@Test("Overrides on with a document: menu drives the local choice")
func menuPolicyUsesLocalWhenOverridesOn() {
  let global = ColorSchemeChoice(initialSelection: nil)
  let local = ColorSchemeChoice(initialSelection: nil)

  let (_, resolvedLocal, resolvedGlobal) = menuPolicy(
    appModel: global,
    documentModel: local,
    localTitle: "Local",
    globalTitle: "Global",
    overridesEnabled: true)

  #expect(resolvedLocal === local)
  #expect(resolvedGlobal === global)
}

@MainActor
@Test("Overrides on without a document: menu falls back to global")
func menuPolicyFallsBackToGlobalWithoutDocument() {
  let global = ColorSchemeChoice(initialSelection: nil)

  let (_, resolvedLocal, resolvedGlobal) = menuPolicy(
    appModel: global,
    documentModel: nil as ColorSchemeChoice?,
    localTitle: "Local",
    globalTitle: "Global",
    overridesEnabled: true)

  #expect(resolvedLocal == nil)
  #expect(resolvedGlobal === global)
}
