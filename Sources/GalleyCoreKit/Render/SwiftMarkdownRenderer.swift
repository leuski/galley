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
    var visitor = HTMLVisitor(annotatesSourceLines: true)
    visitor.visit(document)
    return visitor.html
  }
}

private struct HTMLVisitor: MarkupVisitor {
  typealias Result = Void

  let annotatesSourceLines: Bool
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
    visitChildren(of: listItem)
    html += "</li>\n"
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
