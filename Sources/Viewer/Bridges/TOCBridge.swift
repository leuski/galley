import Foundation
import GalleyCoreKit
import OSLog
import WebKit

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
@MainActor @Observable
final class TOCBridge: JavaScriptBridge {
  static let messageName = "toc"

  /// Heading extraction + active-section tracker. Source lives in
  /// `Resources/Scripts/tocController.js`; the message name and the
  /// 100px active-threshold (matches GitBook / MDN; a touch below the
  /// typical title-bar / toolbar inset) are hardcoded there. Update
  /// the JS file in lockstep with `messageName` here.
  static let userScript = scriptFromResource(name: "tocController")

  /// Headings extracted from the rendered DOM after each load. The
  /// `TOCBridge` user script walks `<h1>…<h6>`, assigns synthetic ids
  /// to any heading without one, and posts the flat list. The
  /// sidebar reads this and indents by `level`.
  private(set) var headings: [TOCEntry] = []

  /// Id of the heading whose section the reader is currently in,
  /// updated by `TOCBridge` on scroll. `nil` means the user is
  /// scrolled above the first heading. The sidebar highlights the
  /// matching row.
  var activeHeadingID: TOCEntry.ID?

  @ObservationIgnored var isScrolling = false

  func handle(value msg: Value) {
    // A headings message always carries `items` (possibly empty); an
    // active-heading message never does. `activeId == nil` means the
    // reader scrolled above the first heading.
    if let items = msg.items {
      headings = items.map {
        TOCEntry(
          id: TOCEntry.ID(rawValue: $0.id), level: $0.level, text: $0.text)
      }
    } else {
      guard !isScrolling else { return }
      activeHeadingID = msg.activeId.map { identifier in
        TOCEntry.ID(rawValue: identifier) }
    }
  }

  func clear() {
    headings = []
    activeHeadingID = nil
  }

  struct Value: Decodable {
    let items: [Item]?
    let activeId: String?
    struct Item: Decodable {
      let id: String
      let level: Int
      let text: String
    }
  }
}
