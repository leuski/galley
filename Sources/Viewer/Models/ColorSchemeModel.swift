//
//  ColorSchemeModel.swift
//  Galley
//
//  Created by Anton Leuski on 5/18/26.
//

import Foundation
import GalleyCoreKit
import SwiftUI

struct ColorSchemePolicy: SelectablePolicy<DocumentColorScheme> {
  typealias PersistentSelectionRepresentation = NamedPair<Element>
  typealias Selection = Element

  var elements: [Element] { DocumentColorScheme.allCases }
  var defaultSelection: Selection { .light }
  func decode(_ value: PersistentSelectionRepresentation) -> Selection? {
    value.id
  }
  func encode(_ value: Selection) -> PersistentSelectionRepresentation {
    .init(id: value.id, name: String(localized: value.name))
  }
  func contains(_ value: Selection) -> Bool {
    true
  }
}

typealias ColorSchemeChoice = SelectableModel<ColorSchemePolicy>

extension ColorSchemeChoice {
  convenience init(
    initialSelection: PersistentSelectionRepresentation? = nil,
    notifier: Notifier? = nil)
  {
    self.init(
      source: ColorSchemePolicy(),
      initialSelection: initialSelection,
      notifier: notifier)
  }
}

extension DocumentColorScheme: SectionedChoiceValue {
}
