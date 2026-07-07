//
//  SceneColorSchemeModel.swift
//  Galley
//
//  Created by Anton Leuski on 5/18/26.
//

import GalleyCoreKit
import SwiftUI

typealias SceneColorSchemeChoice = SelectableModel<SceneSelectablePolicy<
  ColorSchemePolicy>>

extension SceneColorSchemeChoice {
  convenience init(
    source: ColorSchemeChoice,
    initialSelection: PersistentSelectionRepresentation? = nil,
    notifier: Notifier? = nil)
  {
    self.init(
      source: .init(source),
      initialSelection: initialSelection,
      notifier: notifier)
  }
}
