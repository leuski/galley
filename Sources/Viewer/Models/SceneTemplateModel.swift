//
//  SceneTemplateModel.swift
//  Galley
//
//  Created by Anton Leuski on 4/29/26.
//

import GalleyCoreKit
import SwiftUI

typealias SceneTemplateChoice = SelectableModel<SceneSelectablePolicy<
  TemplatePolicy>>

extension SceneTemplateChoice {
  public convenience init(
    source: TemplateChoice,
    initialSelection: PersistentSelectionRepresentation? = nil,
    notifier: Notifier? = nil)
  {
    self.init(
      source: .init(source),
      initialSelection: initialSelection,
      notifier: notifier)
  }
}
