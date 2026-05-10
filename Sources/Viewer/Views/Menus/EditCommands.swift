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
      Action.find(model).menuItem()
      Action.useSelectionForFind(model).menuItem()
      Action.findNext(model).menuItem()
      Action.findPrevious(model).menuItem()

      Divider()
    }
  }
}
