import Foundation

/// Filename extensions recognised as Markdown source. Used by the file
/// open panel and by the request router alike.
public enum MarkdownFileTypes {
  public static let extensions: Set<String> = [
    "md", "markdown", "mdown", "mmd"
  ]
}
