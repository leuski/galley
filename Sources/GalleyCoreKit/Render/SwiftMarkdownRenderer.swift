import Foundation
import Markdown

/// Built-in renderer backed by `swiftlang/swift-markdown`. Always available
/// and used as the default fallback when no external processor is selected.
///
/// When `annotatesSourceLines` is `true`, every block element receives a
/// `data-source-line="N"` attribute pointing back at the originating line
/// in the markdown source. The attribute is invisible to readers but lets
/// editor-coupling code map clicks in the rendered preview back to the
/// source.
public struct SwiftMarkdownRenderer: MarkdownRenderer {
  public init() {
  }

  public func render(_ source: String, baseURL: URL) async throws -> String {
    let document = Document(parsing: source)
    var visitor = HTMLVisitor(
      annotatesSourceLines: true,
      sourceLines: source.split(
        separator: "\n", omittingEmptySubsequences: false
      ).map(String.init)
    )
    visitor.visit(document)
    return visitor.html
  }
}

private struct HTMLVisitor: MarkupVisitor {
  typealias Result = Void

  let annotatesSourceLines: Bool
  let sourceLines: [String]
  var html = ""

  mutating func defaultVisit(_ markup: any Markup) {
    visitChildren(of: markup)
  }

  private mutating func visitChildren(of markup: any Markup) {
    for child in markup.children {
      visit(child)
    }
  }

  private func sourceAttr(for markup: any Markup) -> String {
    guard annotatesSourceLines, let line = markup.range?.lowerBound.line
    else { return "" }
    return " data-source-line=\"\(line)\""
  }

  // MARK: - Block elements

  mutating func visitDocument(_ document: Document) {
    visitChildren(of: document)
  }

  mutating func visitHeading(_ heading: Heading) {
    let level = max(1, min(heading.level, 6))
    html += "<h\(level)\(sourceAttr(for: heading))>"
    visitChildren(of: heading)
    html += "</h\(level)>\n"
  }

  mutating func visitParagraph(_ paragraph: Paragraph) {
    html += "<p\(sourceAttr(for: paragraph))>"
    visitChildren(of: paragraph)
    html += "</p>\n"
  }

  mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
    html += "<blockquote\(sourceAttr(for: blockQuote))>\n"
    visitChildren(of: blockQuote)
    html += "</blockquote>\n"
  }

  mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
    let langClass = codeBlock.language.flatMap {
      $0.isEmpty ? nil : " class=\"language-\($0.htmlAttributeEscaped)\""
    } ?? ""
    html += "<pre\(sourceAttr(for: codeBlock))><code\(langClass)>"
    html += codeBlock.code.htmlEscaped
    html += "</code></pre>\n"
  }

  mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
    html += htmlBlock.rawHTML
  }

  mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
    html += "<hr\(sourceAttr(for: thematicBreak))>\n"
  }

  mutating func visitOrderedList(_ list: OrderedList) {
    let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
    html += "<ol\(start)\(sourceAttr(for: list))>\n"
    visitChildren(of: list)
    html += "</ol>\n"
  }

  mutating func visitUnorderedList(_ list: UnorderedList) {
    html += "<ul\(sourceAttr(for: list))>\n"
    visitChildren(of: list)
    html += "</ul>\n"
  }

  mutating func visitListItem(_ listItem: ListItem) {
    html += "<li\(sourceAttr(for: listItem))>"
    if let checked = listItem.checkbox {
      let attr = checked == .checked ? " checked" : ""
      html += "<input type=\"checkbox\" disabled\(attr)> "
    }
    let tight = listItem.parent.map(isTightList) ?? false
    for child in listItem.children {
      if tight, let paragraph = child as? Paragraph {
        visitChildren(of: paragraph)
      } else {
        visit(child)
      }
    }
    html += "</li>\n"
  }

  // CommonMark: a list is tight iff no blank lines separate its items and
  // no item contains internal blank lines. swift-markdown doesn't expose
  // the cmark `tight` flag, so we infer it from source ranges.
  private func isTightList(_ list: any Markup) -> Bool {
    let items = list.children.compactMap { $0 as? ListItem }
    guard !items.isEmpty else { return true }
    for (prev, next) in zip(items, items.dropFirst()) {
      if hasBlankLine(between: prev, and: next) { return false }
    }
    for item in items {
      let blocks = Array(item.children)
      if blocks.filter({ $0 is Paragraph }).count > 1 { return false }
      for (prev, next) in zip(blocks, blocks.dropFirst()) {
        if hasBlankLine(between: prev, and: next) { return false }
      }
    }
    return true
  }

  private func hasBlankLine(between prev: any Markup, and next: any Markup)
    -> Bool
  {
    guard let prevStart = prev.range?.lowerBound.line,
      let nextStart = next.range?.lowerBound.line,
      nextStart > prevStart + 1
    else { return false }
    // cmark may extend a block's source range through trailing blank lines,
    // so range.upperBound is unreliable. Scan the original source between
    // prev's start and next's start for an empty line.
    for line in (prevStart + 1)..<nextStart {
      let index = line - 1
      guard index >= 0, index < sourceLines.count else { continue }
      if sourceLines[index].allSatisfy(\.isWhitespace) { return true }
    }
    return false
  }

  mutating func visitTable(_ table: Table) {
    let alignments = table.columnAlignments
    html += "<table\(sourceAttr(for: table))>\n<thead>\n<tr>\n"
    for (index, child) in table.head.children.enumerated() {
      let alignment = index < alignments.count ? alignments[index] : nil
      html += "<th\(alignmentAttribute(alignment))>"
      visitChildren(of: child)
      html += "</th>\n"
    }
    html += "</tr>\n</thead>\n"
    if !table.body.isEmpty {
      html += "<tbody>\n"
      for rowMarkup in table.body.children {
        html += "<tr>\n"
        for (index, cell) in rowMarkup.children.enumerated() {
          let alignment = index < alignments.count ? alignments[index] : nil
          html += "<td\(alignmentAttribute(alignment))>"
          visitChildren(of: cell)
          html += "</td>\n"
        }
        html += "</tr>\n"
      }
      html += "</tbody>\n"
    }
    html += "</table>\n"
  }

  // MARK: - Inline elements

  mutating func visitText(_ text: Text) {
    html += text.string.htmlEscaped
  }

  mutating func visitEmphasis(_ emphasis: Emphasis) {
    html += "<em>"
    visitChildren(of: emphasis)
    html += "</em>"
  }

  mutating func visitStrong(_ strong: Strong) {
    html += "<strong>"
    visitChildren(of: strong)
    html += "</strong>"
  }

  mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
    html += "<del>"
    visitChildren(of: strikethrough)
    html += "</del>"
  }

  mutating func visitInlineCode(_ inlineCode: InlineCode) {
    html += "<code>\(inlineCode.code.htmlEscaped)</code>"
  }

  mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
    html += inlineHTML.rawHTML
  }

  mutating func visitLink(_ link: Link) {
    let href = link.destination ?? ""
    let title = link.title.map { " title=\"\($0.htmlAttributeEscaped)\"" } ?? ""
    html += "<a href=\"\(href.htmlAttributeEscaped)\"\(title)>"
    visitChildren(of: link)
    html += "</a>"
  }

  mutating func visitImage(_ image: Image) {
    let src = (image.source ?? "").htmlAttributeEscaped
    let alt = image.plainText.htmlAttributeEscaped
    let title = image.title
      .map { " title=\"\($0.htmlAttributeEscaped)\"" } ?? ""
    html += "<img src=\"\(src)\" alt=\"\(alt)\"\(title)>"
  }

  mutating func visitLineBreak(_ lineBreak: LineBreak) {
    html += "<br>\n"
  }

  mutating func visitSoftBreak(_ softBreak: SoftBreak) {
    html += "\n"
  }

  // MARK: - Helpers

  private func alignmentAttribute(
    _ alignment: Table.ColumnAlignment?) -> String
  {
    switch alignment {
    case .left: return " style=\"text-align: left\""
    case .center: return " style=\"text-align: center\""
    case .right: return " style=\"text-align: right\""
    case nil: return ""
    }
  }
}
