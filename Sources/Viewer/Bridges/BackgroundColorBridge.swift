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
      msg.color.flatMap(Self.parseCSSColor),
      msg.templateID.map(Template.ID.init(rawValue:)))
  }

  struct Value: Decodable {
    let color: String?
    let templateID: String?
  }

  /// Parses the two shapes `getComputedStyle(...).backgroundColor`
  /// emits — `rgb(r, g, b)` and `rgba(r, g, b, a)`. Components may be
  /// integers (0–255) or floats with a decimal; alpha is 0–1. Returns
  /// `nil` for unparseable input or fully-transparent alpha.
  static func parseCSSColor(_ string: String) -> Color? {
    let lowered = string
      .trimmingCharacters(in: .whitespaces)
      .lowercased()
    guard let openParen = lowered.firstIndex(of: "("),
          let closeParen = lowered.lastIndex(of: ")")
    else { return nil }
    let inside = lowered[
      lowered.index(after: openParen)..<closeParen]
    let parts = inside
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3 || parts.count == 4 else { return nil }
    guard let red = Double(parts[0]),
          let green = Double(parts[1]),
          let blue = Double(parts[2])
    else { return nil }
    let alpha: Double
    if parts.count == 4 {
      guard let parsed = Double(parts[3]) else { return nil }
      alpha = parsed
    } else {
      alpha = 1
    }
    guard alpha > 0 else { return nil }
    return Color(
      .sRGB,
      red: red / 255,
      green: green / 255,
      blue: blue / 255,
      opacity: alpha)
  }
}
