import SwiftUI

/// What the File > Rename… command needs from the frontmost window.
/// `url` lets the menu enable/disable based on whether a renameable
/// document exists; `request` asks the window to present its
/// SwiftUI rename alert. The window owns the alert state, the
/// `TextField` input, the `renameCurrentDocument(toName:)` call, and
/// the post-rename recents/`fileURL` updates — all of which live
/// naturally next to the `DocumentView` that already holds those
/// references.
struct RenameContext: Equatable {
  let url: URL
  let request: @MainActor () -> Void

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

/// Same shape as `RenameContext`: the menu reads `url` for
/// enable/disable, then calls `request` to ask the focused window
/// to run its save-panel + export flow. Equatable on `url` only —
/// the closure isn't comparable, but SwiftUI just needs a
/// stable identity to decide when to invalidate the menu.
struct ExportPDFContext: Equatable {
  let url: URL
  let request: @MainActor () -> Void

  static func == (lhs: ExportPDFContext, rhs: ExportPDFContext) -> Bool {
    lhs.url == rhs.url
  }
}

private struct ExportPDFContextKey: FocusedValueKey {
  typealias Value = ExportPDFContext
}

extension FocusedValues {
  var viewerExportPDFContext: ExportPDFContext? {
    get { self[ExportPDFContextKey.self] }
    set { self[ExportPDFContextKey.self] = newValue }
  }
}
