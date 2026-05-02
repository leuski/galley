import Foundation

public protocol MarkdownRenderer: Sendable {
  /// Convert markdown source to an HTML body fragment.
  func render(_ source: String, baseURL: URL) async throws -> String
}

public enum RendererError: LocalizedError {
  case executableNotFound(name: String)
  case nonZeroExit(code: Int32, stderr: String)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let name):
      return "\(name) not found on PATH"
    case .nonZeroExit(let code, let stderr):
      return "Markdown processor exited with code \(code): \(stderr)"
    }
  }
}
