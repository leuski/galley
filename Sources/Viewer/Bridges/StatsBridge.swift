import Foundation
import GalleyCoreKit
import OSLog
import WebKit
import KosmosAppKit

/// Receives `{ words, characters, headings }` messages from a user
/// script that walks the rendered DOM after each load. Drives the
/// status-bar HUD via `DocumentModel.stats`.
///
/// Counts come from the rendered DOM rather than the source `.md`
/// because the source may include transclusion or other directives
/// the active processor expands at render time — counting raw source
/// would understate (or, for verbatim include syntax that survives
/// the render, overstate) what the reader actually sees.
@MainActor
final class StatsBridge: NSObject, JavaScriptBridge {
  static let messageName = "stats"

  /// Reader script. Source lives in
  /// `Resources/Scripts/statsReader.js`; the message name is
  /// hardcoded there and must match `messageName`.
  static let userScript: String = Bundle.main.requiredString(
    forResource: "statsReader", withExtension: "js")

  /// Set by the owning DocumentModel. Receives the freshly-computed
  /// counts every time the rendered document finishes loading.
  var onStats: ((DocumentStats) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "StatsBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let words = intValue(body["words"]),
          let characters = intValue(body["characters"]),
          let headings = intValue(body["headings"])
    else {
      logMalformedMessage(message.body)
      return
    }
    onStats?(DocumentStats(
      wordCount: words,
      characterCount: characters,
      headingCount: headings))
  }

  /// JS numbers cross the bridge as either `Int` or `NSNumber`
  /// depending on size; accept both rather than assume one.
  private func intValue(_ raw: Any?) -> Int? {
    if let value = raw as? Int { return value }
    if let value = raw as? NSNumber { return value.intValue }
    return nil
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed stats message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
