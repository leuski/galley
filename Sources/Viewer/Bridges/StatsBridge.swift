import Foundation
import GalleyCoreKit
import OSLog
import WebKit

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
@Observable
final class StatsBridge: JavaScriptBridge {
  static let messageName = "stats"

  /// Reader script. Source lives in
  /// `Resources/Scripts/statsReader.js`; the message name is
  /// hardcoded there and must match `messageName`.
  static let userScript = scriptFromResource(name: "statsReader")

  /// Set by the owning DocumentModel. Receives the freshly-computed
  /// counts every time the rendered document finishes loading.
  private(set) var stats: DocumentStats = .empty

  func clear() {
    stats = .empty
  }

  func handle(value msg: Value) {
    stats = DocumentStats(
      wordCount: msg.words,
      characterCount: msg.characters,
      headingCount: msg.headings)
  }

  struct Value: Decodable, Hashable, Sendable {
    let words: Int
    let characters: Int
    let headings: Int
  }
}
