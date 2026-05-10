import Foundation

/// Counts derived from the rendered document, populated by
/// `StatsBridge` after each load. Reading time is computed on demand
/// from `wordCount` against the user-configured words-per-minute, so
/// changing the WPM preference does not require re-running the JS.
struct DocumentStats: Equatable, Sendable {
  let wordCount: Int
  let characterCount: Int
  let headingCount: Int

  static let empty = DocumentStats(
    wordCount: 0, characterCount: 0, headingCount: 0)

  /// Reading time in seconds. Returns 0 for an empty document or a
  /// non-positive WPM (which would otherwise divide by zero).
  func readingTime(wordsPerMinute: Int) -> TimeInterval {
    guard wordsPerMinute > 0, wordCount > 0 else { return 0 }
    return Double(wordCount) / Double(wordsPerMinute) * 60
  }
}
