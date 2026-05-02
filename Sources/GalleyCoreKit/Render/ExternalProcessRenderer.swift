import Foundation
import ALFoundation

/// Renders markdown by piping the source through an external CLI tool.
/// Used for every BBEdit-style external processor (MultiMarkdown,
/// Discount, Pandoc, cmark-gfm, Classic Markdown.pl, …).
struct ExternalProcessRenderer: MarkdownRenderer {
  let toolName: String
  let arguments: [String]
  let executableURL: URL

  static func discover(
    toolName: String,
    arguments: [String] = []
  ) async -> ExternalProcessRenderer? {
    guard let url = try? await URL(command: toolName), url.isExecutable
    else { return nil }
    return ExternalProcessRenderer(
      toolName: toolName,
      arguments: arguments,
      executableURL: url)
  }

  func render(_ source: String, baseURL: URL) async throws -> String {
    guard executableURL.isExecutable else {
      throw RendererError.executableNotFound(name: toolName)
    }

    let streams = ProcessStreams.inMemory
      .map(input: source.data(using: .utf8))
      .memorizedError()

    let result = try await Process.runAndCapture(
      executableURL,
      with: arguments as [ProcessArgument],
      at: baseURL.parent,
      streams: streams)

    if result.terminationStatus != 0 {
      throw RendererError.nonZeroExit(
        code: result.terminationStatus,
        stderr: result.error)
    }
    return result.output
  }
}
