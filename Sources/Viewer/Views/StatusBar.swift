import GalleyCoreKit
import SwiftUI

/// Footer strip at the bottom of a document window. Surfaces word
/// count, non-whitespace character count, heading count, and an
/// estimated reading time computed from `DocumentStats.wordCount`
/// against the user's configured words-per-minute pace. Driven by
/// `DocumentModel.stats`, which `StatsBridge` refreshes after each
/// render.
struct StatusBar: View {
  let stats: DocumentStats
  let wordsPerMinute: Int

  var body: some View {
    HStack(spacing: 16) {
      label("\(formatted(stats.wordCount)) words")
      label("\(formatted(stats.characterCount)) characters")
      label("\(formatted(stats.headingCount)) headings")
      label(readingTimeLabel)
      Spacer(minLength: 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .combine)
  }

  private var readingTimeLabel: String {
    let seconds = stats.readingTime(wordsPerMinute: wordsPerMinute)
    if seconds <= 0 { return "— min read" }
    let minutes = Int((seconds / 60).rounded(.up))
    if minutes < 1 { return "<1 min read" }
    return "\(formatted(minutes)) min read"
  }

  private func label(_ text: String) -> Text { Text(text) }

  private func formatted(_ count: Int) -> String {
    count.formatted(.number)
  }
}
