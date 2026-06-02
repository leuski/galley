import Foundation
import GalleyCoreKit
import OSLog
import WebKit
import KosmosAppKit

/// Receives two kinds of messages from a user script that walks the
/// rendered document's `<h1>…<h6>` tree after each load:
///
/// - `{ items: [{ id, level, text }, ...] }` — the heading list,
///   posted once per load. The script assigns synthetic ids to
///   headings that lack one, so the sidebar can target every entry
///   via `getElementById` regardless of which renderer produced the
///   HTML (swift-markdown / pandoc / cmark-gfm / multimarkdown / etc.).
/// - `{ activeId: <String?> }` — the currently-active heading,
///   recomputed on scroll. "Active" is the last heading whose top
///   edge has scrolled past a threshold near the top of the
///   viewport — the convention every doc site uses to track the
///   reader's section without a cursor. `nil` means the user is
///   scrolled above the first heading.
@MainActor
final class TOCBridge: NSObject, JavaScriptBridge {
  static let messageName = "toc"

  /// Heading extraction + active-section tracker. Source lives in
  /// `Resources/Scripts/tocController.js`; the message name and the
  /// 100px active-threshold (matches GitBook / MDN; a touch below the
  /// typical title-bar / toolbar inset) are hardcoded there. Update
  /// the JS file in lockstep with `messageName` here.
  static let userScript: String = Bundle.main.requiredString(
    forResource: "tocController", withExtension: "js")

  /// Set by the owning DocumentModel; receives the freshly-extracted
  /// heading list every time the page loads.
  var onHeadings: (([TOCEntry]) -> Void)?

  /// Set by the owning DocumentModel; receives the active heading id
  /// (or `nil` when the user is above all headings) on every change.
  var onActiveHeading: ((String?) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "TOCBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any] else {
      logMalformedMessage(message.body)
      return
    }
    if let items = body["items"] as? [[String: Any]] {
      let headings: [TOCEntry] = items.compactMap { entry in
        guard let id = entry["id"] as? String,
              let text = entry["text"] as? String,
              let level = entry["level"] as? Int
        else { return nil }
        return TOCEntry(id: id, level: level, text: text)
      }
      onHeadings?(headings)
      return
    }
    if body.keys.contains("activeId") {
      let id = body["activeId"] as? String
      onActiveHeading?(id)
      return
    }
    logMalformedMessage(message.body)
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed toc message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
