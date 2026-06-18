import Foundation

/// A single heading extracted from the rendered document, used by the
/// Viewer's table-of-contents sidebar. The id is what the page sets
/// as the `<h*>` element's `id` attribute, so the sidebar can target
/// it via `getElementById` when scrolling.
///
/// Named `TOCEntry` rather than `Heading` to avoid a collision with
/// swift-markdown's `Heading` AST node, which is also visible inside
/// this module.
public struct TOCEntry: Sendable, Hashable, Identifiable {
  public let id: ID
  public let level: Int
  public let text: String

  public struct ID: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }
  }

  public init(id: ID, level: Int, text: String) {
    self.id = id
    self.level = level
    self.text = text
  }
}
