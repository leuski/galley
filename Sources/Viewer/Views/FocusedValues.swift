import SwiftUI

/// Bundle of state the File > Rename… command needs from the
/// frontmost window — the URL to rename plus a callback that lets
/// the window record the new URL with the system Open Recent list
/// and update its WindowGroup presentation value.
struct RenameContext: Equatable {
  let url: URL?
  let apply: @MainActor (URL) -> Void

  static func == (lhs: RenameContext, rhs: RenameContext) -> Bool {
    lhs.url == rhs.url
  }
}

private struct RenameContextKey: FocusedValueKey {
  typealias Value = RenameContext
}

extension FocusedValues {
  var viewerRenameContext: RenameContext? {
    get { self[RenameContextKey.self] }
    set { self[RenameContextKey.self] = newValue }
  }
}

private struct DocumentModelKey: FocusedValueKey {
  typealias Value = DocumentModel
}

extension FocusedValues {
  var documentModel: DocumentModel? {
    get { self[DocumentModelKey.self] }
    set { self[DocumentModelKey.self] = newValue }
  }
}
