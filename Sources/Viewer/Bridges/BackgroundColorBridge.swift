import Foundation
import GalleyCoreKit
import OSLog
import SwiftUI
import WebKit

/// Receives the rendered page's computed background color (the
/// `html` element's, falling back to `body`) so the SwiftUI host can
/// paint a matching color behind translucent toolbar / sidebar
/// chrome — creating the illusion that the document extends
/// edge-to-edge.
///
/// Message body shape: `{ "color": "rgb(r,g,b)" | "rgba(r,g,b,a)" |
/// null, "templateID": "<id>" | null }`. `templateID` carries the
/// id of the template that produced the page reporting the color
/// (read from the `<meta name="galley-template-id">` tag
/// `Template.composeHTML` injects). The Swift handler attributes
/// posts to that template, not to the currently-selected one — the
/// two diverge while the user switches templates faster than the
/// WebView can reload.
@MainActor
final class BackgroundColorBridge: JavaScriptBridge {
  /// JS handler name. Script calls
  /// `window.webkit.messageHandlers.backgroundColor.postMessage(...)`.
  static let messageName = "backgroundColor"

  /// Reader script. Source lives in
  /// `Resources/Scripts/backgroundColorReader.js`; the message name
  /// is hardcoded there and must match `messageName`.
  static let userScript = scriptFromResource(name: "backgroundColorReader")

  /// Set by the owning DocumentModel. Receives the parsed color
  /// (`nil` for transparent / malformed payloads) and the
  /// `templateID` the page identified itself with (`nil` when the
  /// page predates the meta-injection or the meta was stripped by a
  /// user template).
  var onColor: ((Color?, Template.ID?) -> Void)?

  func handle(message: WKScriptMessage, error: any Error) {
    Self.handle(message: message, error: error)
    onColor?(nil, nil)
  }

  func handle(value msg: Value) {
    // `color == nil` is an explicit JS `null` — both `html` and `body`
    // were transparent — so the host falls back to the system default.
    // A present-but-unparseable color also resolves to `nil` here.
    onColor?(
      msg.color.flatMap{ CSSColor($0)?.srgb.color },
      msg.templateID.map(Template.ID.init(rawValue:)))
  }

  struct Value: Decodable {
    let color: String?
    let templateID: String?
  }
}
