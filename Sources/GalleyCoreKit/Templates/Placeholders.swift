import Foundation
import KosmosAppKit

public struct PlaceholderContext: Sendable {
  public let documentContent: String
  public let documentURL: URL
  public let origin: URL

  public init(documentContent: String, documentURL: URL, origin: URL) {
    self.documentContent = documentContent
    self.documentURL = documentURL
    self.origin = origin
  }

  static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter
  }()

  public func substitute(into template: String, now: Date = Date()) -> String {
    let baseHref = origin.appendingPreview(documentURL.parent)
      .absoluteString.appendingSlash

    let fileName = documentURL.lastPathComponent
    let baseName = documentURL.fileName
    let ext = documentURL.pathExtension
    // `#TITLE#` is the author-intended document title: the first
    // `<h1>` of the rendered body, falling back to the filename's
    // basename when the document has none. Template authors who want
    // the filename verbatim can still use `#FILE#` / `#BASENAME#`.
    let title = HTMLHeadings.firstH1Text(in: documentContent) ?? baseName

    // Substitute metadata placeholders in the template first, then inject
    // the document body. Doing it the other way round would re-scan the
    // body for `#TITLE#`, `#TIME#`, etc. — so a user writing those tokens
    // in their markdown (even inside a code span) would get them
    // template-substituted instead of rendered as literal text.
    let withMetadata = template.substituting(substitutions: [
      "#TITLE#": title.htmlAttributeEscaped,
      "#BASE#": baseHref.htmlAttributeEscaped,
      "#FILE#": fileName.htmlAttributeEscaped,
      "#BASENAME#": baseName.htmlAttributeEscaped,
      "#FILE_EXTENSION#": ext.htmlAttributeEscaped,
      "#DATE#": Self.dateFormatter.string(from: now).htmlAttributeEscaped,
      "#TIME#": Self.timeFormatter.string(from: now).htmlAttributeEscaped
    ])
    return withMetadata.replacingOccurrences(
      of: "#DOCUMENT_CONTENT#", with: documentContent)
  }
}
