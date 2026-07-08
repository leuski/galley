//
//  EditorStore+viewer.swift
//  Galley
//
//  Created by Anton Leuski on 7/7/26.
//

#if os(macOS)
import GalleyCoreKit

extension EditorStore {
  static let shared = EditorStore(Defaults.shared)
}

extension EditorPolicy {
  static let shared = EditorPolicy(EditorStore.shared)
}

extension Defaults {
  @MainActor public var resolvedEditor: Editor {
    EditorStore.shared.anyEditor(forID: editor?.id)
  }
}

#endif
