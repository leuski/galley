import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("PendingScrollLines")
struct PendingScrollLinesTests {
  @Test("Empty by default")
  func emptyByDefault() {
    let lines = PendingScrollLines()
    #expect(lines.isEmpty)
  }

  @Test("Stash and consume round-trip")
  func stashConsumeRoundTrip() {
    var lines = PendingScrollLines()
    let url = URL(fileURLWithPath: "/tmp/file.md")
    lines.stash(42, for: url)
    #expect(!lines.isEmpty)
    #expect(lines.peek(for: url) == 42)
    #expect(lines.consume(for: url) == 42)
    #expect(lines.consume(for: url) == nil)
    #expect(lines.isEmpty)
  }

  @Test("Different URLs are tracked independently")
  func independentURLs() {
    var lines = PendingScrollLines()
    let a = URL(fileURLWithPath: "/tmp/a.md")
    let b = URL(fileURLWithPath: "/tmp/b.md")
    lines.stash(10, for: a)
    lines.stash(20, for: b)
    #expect(lines.consume(for: a) == 10)
    #expect(lines.consume(for: b) == 20)
  }

  @Test("Last stash wins for the same URL")
  func lastStashWins() {
    var lines = PendingScrollLines()
    let url = URL(fileURLWithPath: "/tmp/file.md")
    lines.stash(10, for: url)
    lines.stash(99, for: url)
    #expect(lines.consume(for: url) == 99)
  }

  @Test("Keys are normalized so encoding/format variations match")
  func normalizedKeys() {
    var lines = PendingScrollLines()
    // Same path, different surface forms — must hit the same slot.
    let original = URL(fileURLWithPath: "/tmp/foo bar.md")
    let viaString = URL(string: "file:///tmp/foo%20bar.md")!
    lines.stash(7, for: original)
    #expect(lines.consume(for: viaString) == 7)
  }

  @Test("Consume on missing URL returns nil")
  func consumeMissing() {
    var lines = PendingScrollLines()
    let url = URL(fileURLWithPath: "/tmp/missing.md")
    #expect(lines.consume(for: url) == nil)
  }
}
