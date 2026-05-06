import Foundation

/// A single heading extracted from the rendered document, used by the
/// Viewer's table-of-contents sidebar. The id is what the page sets
/// as the `<h*>` element's `id` attribute, so the sidebar can target
/// it via `getElementById` when scrolling.
///
/// Named `TOCEntry` rather than `Heading` to avoid a collision with
/// swift-markdown's `Heading` AST node, which is also visible inside
/// this module.
public struct TOCEntry: Sendable, Equatable, Identifiable {
  public let id: String
  public let level: Int
  public let text: String

  public init(id: String, level: Int, text: String) {
    self.id = id
    self.level = level
    self.text = text
  }
}
