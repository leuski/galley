import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("URLNormalizer")
struct URLNormalizerTests {
  @Test("file:// URL passes through unchanged with no scroll line")
  func fileURLPassthrough() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let outcome = URLNormalizer.normalize(url)
    #expect(outcome == .document(url, scrollLine: nil))
  }

  @Test("galley://settings becomes openSettings")
  func settingsURL() {
    let url = URL(string: "galley://settings")!
    #expect(URLNormalizer.normalize(url) == .openSettings)
  }

  @Test("galley:// scheme is case-insensitive")
  func schemeCaseInsensitive() {
    let lower = URL(string: "galley:///tmp/a.md")!
    let mixed = URL(string: "Galley:///tmp/a.md")!
    let upper = URL(string: "GALLEY:///tmp/a.md")!
    let expected = URL(fileURLWithPath: "/tmp/a.md")
    for url in [lower, mixed, upper] {
      #expect(URLNormalizer.normalize(url)
              == .document(expected, scrollLine: nil))
    }
  }

  @Test("settings host is case-insensitive")
  func settingsHostCaseInsensitive() {
    let upper = URL(string: "galley://Settings")!
    #expect(URLNormalizer.normalize(upper) == .openSettings)
  }

  @Test("galley://path?line=N stashes scroll line")
  func scrollLineExtracted() {
    let url = URL(string: "galley:///tmp/note.md?line=42")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(URLNormalizer.normalize(url)
            == .document(expected, scrollLine: 42))
  }

  @Test("Non-positive scroll lines are dropped")
  func nonPositiveLineDropped() {
    let zero = URL(string: "galley:///tmp/note.md?line=0")!
    let negative = URL(string: "galley:///tmp/note.md?line=-5")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(URLNormalizer.normalize(zero)
            == .document(expected, scrollLine: nil))
    #expect(URLNormalizer.normalize(negative)
            == .document(expected, scrollLine: nil))
  }

  @Test("Non-numeric line is dropped")
  func nonNumericLineDropped() {
    let url = URL(string: "galley:///tmp/note.md?line=foo")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(URLNormalizer.normalize(url)
            == .document(expected, scrollLine: nil))
  }

  @Test("galley:// with empty path is unparseable")
  func emptyPathUnparseable() {
    let url = URL(string: "galley://")!
    if case .unparseable = URLNormalizer.normalize(url) {
      // expected
    } else {
      Issue.record("Expected .unparseable, got \(URLNormalizer.normalize(url))")
    }
  }

  @Test("Other extra query items are ignored")
  func extraQueryIgnored() {
    let url = URL(string: "galley:///tmp/note.md?foo=bar&line=7&baz=qux")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(URLNormalizer.normalize(url)
            == .document(expected, scrollLine: 7))
  }

  @Test("http:// URLs pass through unchanged")
  func httpPassthrough() {
    let url = URL(string: "https://example.com/page.md")!
    #expect(URLNormalizer.normalize(url)
            == .document(url, scrollLine: nil))
  }
}
