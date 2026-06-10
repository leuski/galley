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
  static let userScript: String = Bundle(for: TOCBridge.self)
    .requiredString(forResource: "tocController", withExtension: "js")

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
    guard let msg = try? message.decodedBody(Message.self) else {
      logMalformedMessage(message.body)
      return
    }
    // A headings message always carries `items` (possibly empty); an
    // active-heading message never does. `activeId == nil` means the
    // reader scrolled above the first heading.
    if let items = msg.items {
      onHeadings?(items.map {
        TOCEntry(id: $0.id, level: $0.level, text: $0.text)
      })
    } else {
      onActiveHeading?(msg.activeId)
    }
  }

  private struct Message: Decodable {
    let items: [Item]?
    let activeId: String?
    struct Item: Decodable {
      let id: String
      let level: Int
      let text: String
    }
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed toc message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
