import Foundation
import WebKit
import OSLog
import GalleyCoreKit
import KosmosAppKit

/// Receives `{ "line": <Int> }` messages from the rendered preview and
/// opens the current document in BBEdit at that line. The bridge has no
/// own knowledge of the file path — it reads it from `documentURL`,
/// which the owning DocumentModel keeps current.
@MainActor
final class EditorBridge: NSObject, JavaScriptBridge {
  /// Name of the JavaScript message handler. JS calls
  /// `window.webkit.messageHandlers.editor.postMessage({ line: N })`.
  static let messageName = "editor"

  /// Single combined click handler for cmd-click → editor and plain
  /// click → in-window navigation. Source lives in
  /// `Resources/Scripts/editorClick.js` — message names are
  /// hardcoded there and must match `messageName` here and
  /// `LinkBridge.messageName`.
  static let userScript: String = Bundle.main.requiredString(
    forResource: "editorClick", withExtension: "js")

  var documentURL: URL?

  /// Set by the owning DocumentModel; receives the line clicked.
  /// Routing the actual open call through the model lets it consult
  /// the user's `EditorChoice` from `AppModel`.
  var onEditorClick: ((Int) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "EditorBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let line = body["line"] as? Int
    else {
      logMalformedMessage(message.body)
      return
    }
    onEditorClick?(line)
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed editor message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
