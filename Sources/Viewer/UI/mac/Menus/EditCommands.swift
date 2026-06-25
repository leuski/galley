//
//  EditCommands.swift
//  Galley
//
//  Created by Anton Leuski on 5/8/26.
//
#if os(macOS)
import GalleyCoreKit
import SwiftUI

struct EditCommands: Commands {
  @FocusedValue(\.documentModel) private var model

  var body: some Commands {
    CommandGroup(replacing: .textEditing) {
      Action.find(model?.find).menuItem()
      Action.useSelectionForFind(model?.find).menuItem()
      Action.findNext(model?.find).menuItem()
      Action.findPrevious(model?.find).menuItem()

      Divider()
    }
  }
}
#endif
