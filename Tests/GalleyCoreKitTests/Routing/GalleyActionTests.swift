import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("GalleyAction")
struct GalleyActionTests {
  @Test("file:// URL passes through unchanged with no scroll line")
  func fileURLPassthrough() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let outcome = url.galleyAction
    #expect(outcome == .document(url, scrollLine: nil))
  }

  @Test("galley://settings becomes openSettings with no tab")
  func settingsURL() {
    let url = URL(string: "galley://settings")!
    #expect(url.galleyAction == .openSettings(nil))
  }

  @Test("galley://settings?tab=<id> carries the tab")
  func settingsTabExtracted() {
    for tab in SettingsTab.allCases {
      let url = URL(string: "galley://settings?tab=\(tab.rawValue)")!
      #expect(url.galleyAction == .openSettings(tab))
    }
  }

  @Test("Settings tab value is case-insensitive")
  func settingsTabCaseInsensitive() {
    let url = URL(string: "galley://settings?tab=SERVER")!
    #expect(url.galleyAction == .openSettings(.server))
  }

  @Test("Unknown settings tab is dropped")
  func settingsTabUnknownDropped() {
    let url = URL(string: "galley://settings?tab=bogus")!
    #expect(url.galleyAction == .openSettings(nil))
  }

  @Test("galley:// scheme is case-insensitive")
  func schemeCaseInsensitive() {
    let lower = URL(string: "galley:///tmp/a.md")!
    let mixed = URL(string: "Galley:///tmp/a.md")!
    let upper = URL(string: "GALLEY:///tmp/a.md")!
    let expected = URL(fileURLWithPath: "/tmp/a.md")
    for url in [lower, mixed, upper] {
      #expect(url.galleyAction
              == .document(expected, scrollLine: nil))
    }
  }

  @Test("settings host is case-insensitive")
  func settingsHostCaseInsensitive() {
    let upper = URL(string: "galley://Settings")!
    #expect(upper.galleyAction == .openSettings(nil))
  }

  @Test("galley://path?line=N stashes scroll line")
  func scrollLineExtracted() {
    let url = URL(string: "galley:///tmp/note.md?line=42")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(url.galleyAction
            == .document(expected, scrollLine: 42))
  }

  @Test("Non-positive scroll lines are dropped")
  func nonPositiveLineDropped() {
    let zero = URL(string: "galley:///tmp/note.md?line=0")!
    let negative = URL(string: "galley:///tmp/note.md?line=-5")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(zero.galleyAction
            == .document(expected, scrollLine: nil))
    #expect(negative.galleyAction
            == .document(expected, scrollLine: nil))
  }

  @Test("Non-numeric line is dropped")
  func nonNumericLineDropped() {
    let url = URL(string: "galley:///tmp/note.md?line=foo")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(url.galleyAction
            == .document(expected, scrollLine: nil))
  }

  @Test("galley:// with empty path is unparseable")
  func emptyPathUnparseable() {
    let url = URL(string: "galley://")!
    if case .unparseable = url.galleyAction {
      // expected
    } else {
      Issue.record("Expected .unparseable, got \(url.galleyAction)")
    }
  }

  @Test("Other extra query items are ignored")
  func extraQueryIgnored() {
    let url = URL(string: "galley:///tmp/note.md?foo=bar&line=7&baz=qux")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(url.galleyAction
            == .document(expected, scrollLine: 7))
  }

  @Test("http:// URLs pass through unchanged")
  func httpPassthrough() {
    let url = URL(string: "https://example.com/page.md")!
    #expect(url.galleyAction
            == .document(url, scrollLine: nil))
  }

  // MARK: - Path encoding edge cases

  @Test("Percent-encoded space in galley:// path decodes to a real path")
  func pathPercentEncodedSpace() {
    let url = URL(string: "galley:///tmp/foo%20bar.md")!
    let expected = URL(fileURLWithPath: "/tmp/foo bar.md")
    #expect(url.galleyAction == .document(expected, scrollLine: nil))
  }

  @Test("Path with unicode characters round-trips")
  func pathUnicode() {
    let url = URL(string: "galley:///tmp/привет.md")!
    let expected = URL(fileURLWithPath: "/tmp/привет.md")
    #expect(url.galleyAction == .document(expected, scrollLine: nil))
  }

  /// Fragments (`#anchor`) are dropped — the dispatcher has no use
  /// for them, and `Int.init` parsing of `line` doesn't read the
  /// fragment in any case. Pin that fragments don't poison parsing.
  @Test("Fragment after path is ignored, line is still parsed")
  func fragmentIgnoredLineParsed() {
    let url = URL(string: "galley:///tmp/note.md?line=12#anchor")!
    let expected = URL(fileURLWithPath: "/tmp/note.md")
    #expect(url.galleyAction == .document(expected, scrollLine: 12))
  }

  // MARK: - Query item edge cases

  @Test("line= with empty value is dropped")
  func lineEmptyValueDropped() {
    let url = URL(string: "galley:///tmp/a.md?line=")!
    let expected = URL(fileURLWithPath: "/tmp/a.md")
    #expect(url.galleyAction == .document(expected, scrollLine: nil))
  }

  @Test("Floating-point line is dropped (Int parse only)")
  func lineFloatDropped() {
    let url = URL(string: "galley:///tmp/a.md?line=3.14")!
    let expected = URL(fileURLWithPath: "/tmp/a.md")
    #expect(url.galleyAction == .document(expected, scrollLine: nil))
  }

  @Test("Scientific notation line is dropped")
  func lineScientificDropped() {
    let url = URL(string: "galley:///tmp/a.md?line=1e3")!
    let expected = URL(fileURLWithPath: "/tmp/a.md")
    #expect(url.galleyAction == .document(expected, scrollLine: nil))
  }

  @Test("Multiple line= query items: first wins")
  func lineMultipleFirstWins() {
    let url = URL(string: "galley:///tmp/a.md?line=10&line=20")!
    let expected = URL(fileURLWithPath: "/tmp/a.md")
    #expect(url.galleyAction == .document(expected, scrollLine: 10))
  }

  @Test("Very large positive line is preserved as-is")
  func lineLarge() {
    let url = URL(string: "galley:///tmp/a.md?line=999999")!
    let expected = URL(fileURLWithPath: "/tmp/a.md")
    #expect(url.galleyAction == .document(expected, scrollLine: 999_999))
  }

  // MARK: - Settings host edge cases

  /// `tab` query parameter is keyed by exact name "tab" — uppercase
  /// or different name should not match. Pin to detect a regression
  /// if the lookup ever flips to case-insensitive on the param NAME.
  @Test("tab= parameter NAME is case-sensitive (only lowercase 'tab' wins)")
  func settingsTabParamNameCaseSensitive() {
    let url = URL(string: "galley://settings?TAB=server")!
    #expect(url.galleyAction == .openSettings(nil))
  }

  @Test("Settings with no query items returns no tab")
  func settingsEmptyQuery() {
    let url = URL(string: "galley://settings?")!
    #expect(url.galleyAction == .openSettings(nil))
  }

  @Test("Settings with extra unrelated params still returns the tab")
  func settingsTabWithExtras() {
    let url = URL(string: "galley://settings?foo=bar&tab=server&x=y")!
    #expect(url.galleyAction == .openSettings(.server))
  }

  // MARK: - Unparseable cases

  @Test("galley:// with only a query and no path is unparseable")
  func emptyPathWithQueryUnparseable() {
    // host is nil and path is empty — neither settings nor a doc.
    let url = URL(string: "galley://?line=10")!
    if case .unparseable = url.galleyAction { /* expected */ } else {
      Issue.record("Expected .unparseable, got \(url.galleyAction)")
    }
  }

  // MARK: - Cross-scheme passthrough

  @Test("Custom scheme (not galley) passes through as document")
  func customSchemePassthrough() {
    let url = URL(string: "x-galley://local/template/foo.html")!
    #expect(url.galleyAction == .document(url, scrollLine: nil))
  }

  /// All `SettingsTab` cases have stable `rawValue`s — encode them
  /// one more time so a renamed/added case lights up here, not at
  /// runtime when a deep-link first reaches it.
  @Test("SettingsTab rawValues stay stable across the catalog",
        arguments: SettingsTab.allCases)
  func settingsTabRawValueRoundTrip(tab: SettingsTab) {
    let parsed = SettingsTab(rawValue: tab.rawValue)
    #expect(parsed == tab)
  }
}
