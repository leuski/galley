//
//  SceneProcessorModel.swift
//  Galley
//

import GalleyCoreKit
import SwiftUI

typealias SceneProcessorChoice = SelectableModel<SceneSelectablePolicy<
  ProcessorPolicy>>

extension SceneProcessorChoice {
  public convenience init(
    source: ProcessorChoice,
    initialSelection: PersistentSelectionRepresentation? = nil,
    notifier: Notifier? = nil)
  {
    self.init(
      source: .init(source),
      initialSelection: initialSelection,
      notifier: notifier)
  }
}
