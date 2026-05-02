import SwiftUI

/// Bridges the active Viewer window's model into the App's command
/// scene so menu items can drive Back/Forward/Reload on whichever
/// document is frontmost.
private struct ViewerModelKey: FocusedValueKey {
  typealias Value = DocumentModel
}

extension FocusedValues {
  var viewerModel: DocumentModel? {
    get { self[ViewerModelKey.self] }
    set { self[ViewerModelKey.self] = newValue }
  }
}

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

/// Per-window template choice exposed to commands so the override
/// menu in `RenderingCommands` can drive it without going through
/// `DocumentModel`. The struct holds a `Binding` to the active
/// window's `@SceneStorage` slot.
private struct ViewerTemplatesKey: FocusedValueKey {
  typealias Value = SceneTemplateChoice
}

extension FocusedValues {
  var viewerTemplates: SceneTemplateChoice? {
    get { self[ViewerTemplatesKey.self] }
    set { self[ViewerTemplatesKey.self] = newValue }
  }
}

/// Per-window processor choice. Same plumbing as
/// `viewerTemplates`.
private struct ViewerProcessorsKey: FocusedValueKey {
  typealias Value = SceneProcessorChoice
}

extension FocusedValues {
  var viewerProcessors: SceneProcessorChoice? {
    get { self[ViewerProcessorsKey.self] }
    set { self[ViewerProcessorsKey.self] = newValue }
  }
}
