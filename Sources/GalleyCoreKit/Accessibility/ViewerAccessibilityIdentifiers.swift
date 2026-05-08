import Foundation

/// Single source of truth for every UITest-visible accessibility
/// identifier in the Viewer app. Centralizing them here means tests
/// import this catalog rather than hardcoding strings, so renames
/// fail at compile time instead of producing flaky tests.
///
/// Convention: `viewer.<surface>.<element>` — the prefix scopes
/// identifiers to the Viewer so they don't collide with the Server
/// app's own catalog.
public enum ViewerA11yID {
  // MARK: File menu

  public enum FileMenu {
    public static let open = "viewer.file.open"
    public static let openRecentMenu = "viewer.file.openRecent.menu"
    public static let openRecentItem = "viewer.file.openRecent.item"
    public static let openRecentClear = "viewer.file.openRecent.clear"
    public static let rename = "viewer.file.rename"
    public static let openInEditor = "viewer.file.openInEditor"
    public static let exportPDF = "viewer.file.exportPDF"
    public static let pageSetup = "viewer.file.pageSetup"
    public static let print = "viewer.file.print"
  }

  // MARK: View menu

  public enum ViewMenu {
    public static let back = "viewer.view.back"
    public static let forward = "viewer.view.forward"
    public static let reload = "viewer.view.reload"
    public static let zoomIn = "viewer.view.zoomIn"
    public static let zoomOut = "viewer.view.zoomOut"
    public static let actualSize = "viewer.view.actualSize"
    public static let toggleTOC = "viewer.view.toggleTOC"
    public static let find = "viewer.view.find"
    public static let useSelectionForFind =
      "viewer.view.useSelectionForFind"
    public static let findNext = "viewer.view.findNext"
    public static let findPrevious = "viewer.view.findPrevious"
  }

  // MARK: Find bar

  public enum Find {
    public static let toolbar = "viewer.find.toolbar"
    public static let field = "viewer.find.field"
    public static let next = "viewer.find.next"
    public static let previous = "viewer.find.previous"
    public static let close = "viewer.find.close"
    public static let optionsMenu = "viewer.find.optionsMenu"
    public static let ignoreCase = "viewer.find.ignoreCase"
    public static let wholeWord = "viewer.find.wholeWord"
  }

  // MARK: Rendering menu / toolbar

  public enum Rendering {
    public static let processorMenu = "viewer.rendering.processor.menu"
    public static let processorItem = "viewer.rendering.processor.item"
    public static let templateMenu = "viewer.rendering.template.menu"
    public static let templateItem = "viewer.rendering.template.item"
  }

  // MARK: Settings

  public enum Settings {
    public static let openBehaviorPicker = "viewer.settings.openBehavior"
    public static let perDocumentOverridesToggle =
      "viewer.settings.perDocumentOverrides"
    public static let editorChoicePicker = "viewer.settings.editorChoice"
    public static let processorPicker = "viewer.settings.processorPicker"
    public static let templatePicker = "viewer.settings.templatePicker"
  }

  // MARK: Document window

  public enum Document {
    public static let webView = "viewer.document.webView"
    public static let placeholder = "viewer.document.placeholder"
  }
}
