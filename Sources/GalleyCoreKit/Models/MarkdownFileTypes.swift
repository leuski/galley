import Foundation
import UniformTypeIdentifiers

/// Filename extensions recognised as Markdown source. Used by the file
/// open panel and by the request router alike.
public enum MarkdownFileTypes {
  public static let extensions: Set<String> = [
    "md", "markdown", "mdown", "mmd"
  ]
}

public extension UTType {
  static let allMarkdownTypes: [UTType] = (
    [ "md", "markdown", "mdown", "mmd" ]
      .map { UTType.init(filenameExtension: $0) } + [.markdown]
  ).compactMap({$0})

  static let markdown = UTType("net.daringfireball.markdown")

  static let allMarkdownTypesAndPlainText: [UTType] = allMarkdownTypes
  + [.plainText]
}
