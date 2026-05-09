//
//  EditCommands.swift
//  Galley
//
//  Created by Anton Leuski on 5/8/26.
//

import AppKit
import GalleyCoreKit
import SwiftUI

struct EditCommands: Commands {
  @FocusedValue(\.documentModel) private var model

  var body: some Commands {
    CommandGroup(replacing: .textEditing) {
      Action.find.menuItem(model: model)
      Action.useSelectionForFind.menuItem(model: model)
      Action.findNext.menuItem(model: model)
      Action.findPrevious.menuItem(model: model)

      Divider()
    }
  }
}
