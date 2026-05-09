import SwiftUI

/// The focused window's `DocumentModel`, published per-scene by
/// `DocumentView` and read by App-level commands (`FileCommands`,
/// `RenderingCommands`) that need to act on the frontmost document.
///
/// This is the only bridge between the App-level menu bar and a
/// per-window view. Menu actions that flip presentation state — the
/// rename alert, the Export-as-PDF file dialog — call request
/// methods on the model (`requestRename`, `requestExportPDF`); the
/// view's modifiers bind to the matching `@Observable` properties.
private struct DocumentModelKey: FocusedValueKey {
  typealias Value = DocumentModel
}

extension FocusedValues {
  var documentModel: DocumentModel? {
    get { self[DocumentModelKey.self] }
    set { self[DocumentModelKey.self] = newValue }
  }
}
