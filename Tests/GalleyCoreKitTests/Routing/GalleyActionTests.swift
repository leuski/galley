import Foundation
import KosmosAppKit
import Testing
@testable import GalleyCoreKit

@Suite("GalleyAction")
struct GalleyActionTests {
  /// Build a `galley://` document URL the way the production encoder
  /// (`OpenDocumentActivity.url` → `DocumentTarget.url(scheme:)`) does:
  /// the file URL's `absoluteString` is percent-encoded into the path,
  /// so the decoder reconstructs a real `file://` URL. `query` is
  /// appended verbatim so the line-parsing edge cases can inject
  /// malformed values; `fragment` lets a test pin that fragments don't
  /// poison parsing.
  private func galleyDocURL(
    _ fileURL: URL,
    query: [URLQueryItem]? = nil,
    fragment: String? = nil
  ) -> URL {
    var components = URLComponents()
    components.scheme = OpenDocumentActivity.scheme
    components.path = fileURL.absoluteString.percentEncodedForPath
    components.queryItems = query
    components.fragment = fragment
    return components.url!
  }

  @Test("file:// URL passes through unchanged with no scroll line")
  func fileURLPassthrough() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let outcome = OpenDocumentActivity(from: url)
    #expect(outcome == .init(url: url))
  }

  @Test("galley-settings:// becomes openSettings with no tab")
  func settingsURL() {
    let url = URL(string: "galley-settings://")!
    #expect(OpenSettingsActivity(from: url) == .init())
  }

  @Test("galley-settings://?tab=<id> carries the tab")
  func settingsTabExtracted() {
    for tab in SettingsTab.allCases {
      let url = URL(string: "galley-settings://?tab=\(tab.rawValue)")!
      #expect(OpenSettingsActivity(from: url) == .init(tab))
    }
  }

  @Test("Settings tab value is case-insensitive")
  func settingsTabCaseInsensitive() {
    let url = URL(string: "galley-settings://?tab=SERVER")!
    #expect(OpenSettingsActivity(from: url) == .init(.server))
  }

  @Test("Unknown settings tab is dropped")
  func settingsTabUnknownDropped() {
    let url = URL(string: "galley-settings://?tab=bogus")!
    #expect(OpenSettingsActivity(from: url) == .init())
  }

  /// The new `DocumentTarget` parser matches the document scheme
  /// exactly (`components.scheme == "galley"`) — no `.lowercased()`
  /// fold like the retired `URL.galleyAction`. LaunchServices hands
  /// inbound schemes back lowercased, so the canonical lowercase form
  /// round-trips; a mixed/upper-case scheme is not the document scheme
  /// and, not being a `file://` URL either, is rejected.
  @Test("galley:// document scheme must be lowercase")
  func schemeMustBeLowercase() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    #expect(OpenDocumentActivity(from: galleyDocURL(file)) == .init(url: file))
    for scheme in ["Galley", "GALLEY"] {
      var components = URLComponents()
      components.scheme = scheme
      components.path = file.absoluteString.percentEncodedForPath
      #expect(OpenDocumentActivity(from: components.url!) == nil)
    }
  }

  /// Same exact-scheme rule for the settings scheme — the case-fold is
  /// gone, so an upper-case `galley-settings` no longer parses.
  @Test("galley-settings scheme must be lowercase")
  func settingsSchemeMustBeLowercase() {
    let url = URL(string: "GALLEY-SETTINGS://?tab=server")!
    #expect(OpenSettingsActivity(from: url) == nil)
  }

  @Test("Old galley://settings form is no longer settings (now a doc/none)")
  func oldSettingsFormRetired() {
    // The settings deep-link moved to its own scheme; `galley://settings`
    // has an empty path under the document scheme → unparseable.
    let url = URL(string: "galley://settings")!
    #expect(OpenSettingsActivity(from: url) != .init(nil))
  }

  @Test("galley://path?line=N stashes scroll line")
  func scrollLineExtracted() {
    let file = URL(fileURLWithPath: "/tmp/note.md")
    let url = galleyDocURL(file, query: [.init(name: "line", value: "42")])
    #expect(OpenDocumentActivity(from: url) == .init(url: file, scrollLine: 42))
  }

  @Test("Non-positive scroll lines are dropped")
  func nonPositiveLineDropped() {
    let file = URL(fileURLWithPath: "/tmp/note.md")
    let zero = galleyDocURL(file, query: [.init(name: "line", value: "0")])
    let negative = galleyDocURL(file, query: [.init(name: "line", value: "-5")])
    #expect(OpenDocumentActivity(from: zero) == .init(url: file))
    #expect(OpenDocumentActivity(from: negative) == .init(url: file))
  }

  @Test("Non-numeric line is dropped")
  func nonNumericLineDropped() {
    let file = URL(fileURLWithPath: "/tmp/note.md")
    let url = galleyDocURL(file, query: [.init(name: "line", value: "foo")])
    #expect(OpenDocumentActivity(from: url) == .init(url: file))
  }

  @Test("galley:// with empty path is unparseable")
  func emptyPathUnparseable() {
    let url = URL(string: "galley://")!
    let document = OpenDocumentActivity(from: url)
    if nil == document {
      // expected
    } else {
      Issue.record("Expected .unparseable, got \(document)")
    }
  }

  @Test("Other extra query items are ignored")
  func extraQueryIgnored() {
    let file = URL(fileURLWithPath: "/tmp/note.md")
    let url = galleyDocURL(file, query: [
      .init(name: "foo", value: "bar"),
      .init(name: "line", value: "7"),
      .init(name: "baz", value: "qux"),
    ])
    #expect(OpenDocumentActivity(from: url) == .init(url: file, scrollLine: 7))
  }

  /// The retired `URL.galleyAction` passed any non-`galley` URL through
  /// as a document; the new `DocumentTarget` parser only accepts
  /// `file://` URLs and the `galley://` document scheme — every other
  /// scheme is rejected (nil). Pin both an `http(s)://` URL and the
  /// in-process `x-galley://` resolver scheme.
  @Test("Non-file, non-galley URLs are rejected")
  func foreignSchemesRejected() {
    let http = URL(string: "https://example.com/page.md")!
    let xGalley = URL(string: "x-galley://local/template/foo.html")!
    #expect(OpenDocumentActivity(from: http) == nil)
    #expect(OpenDocumentActivity(from: xGalley) == nil)
  }

  // MARK: - Path encoding edge cases

  @Test("Percent-encoded space in galley:// path decodes to a real path")
  func pathPercentEncodedSpace() {
    let file = URL(fileURLWithPath: "/tmp/foo bar.md")
    #expect(OpenDocumentActivity(from: galleyDocURL(file)) == .init(url: file))
  }

  @Test("Path with unicode characters round-trips")
  func pathUnicode() {
    let file = URL(fileURLWithPath: "/tmp/привет.md")
    #expect(OpenDocumentActivity(from: galleyDocURL(file)) == .init(url: file))
  }

  /// Fragments (`#anchor`) are dropped — `DocumentTarget` has no use
  /// for them, and `Int.init` parsing of `line` doesn't read the
  /// fragment in any case. Pin that fragments don't poison parsing.
  @Test("Fragment after path is ignored, line is still parsed")
  func fragmentIgnoredLineParsed() {
    let file = URL(fileURLWithPath: "/tmp/note.md")
    let url = galleyDocURL(
      file, query: [.init(name: "line", value: "12")], fragment: "anchor")
    #expect(OpenDocumentActivity(from: url) == .init(url: file, scrollLine: 12))
  }

  // MARK: - Query item edge cases

  @Test("line= with empty value is dropped")
  func lineEmptyValueDropped() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    let url = galleyDocURL(file, query: [.init(name: "line", value: "")])
    #expect(OpenDocumentActivity(from: url) == .init(url: file))
  }

  @Test("Floating-point line is dropped (Int parse only)")
  func lineFloatDropped() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    let url = galleyDocURL(file, query: [.init(name: "line", value: "3.14")])
    #expect(OpenDocumentActivity(from: url) == .init(url: file))
  }

  @Test("Scientific notation line is dropped")
  func lineScientificDropped() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    let url = galleyDocURL(file, query: [.init(name: "line", value: "1e3")])
    #expect(OpenDocumentActivity(from: url) == .init(url: file))
  }

  @Test("Multiple line= query items: first wins")
  func lineMultipleFirstWins() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    let url = galleyDocURL(file, query: [
      .init(name: "line", value: "10"),
      .init(name: "line", value: "20"),
    ])
    #expect(OpenDocumentActivity(from: url) == .init(url: file, scrollLine: 10))
  }

  @Test("Very large positive line is preserved as-is")
  func lineLarge() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    let url = galleyDocURL(file, query: [.init(name: "line", value: "999999")])
    #expect(
      OpenDocumentActivity(from: url) == .init(url: file, scrollLine: 999_999))
  }

  // MARK: - Settings host edge cases

  /// `tab` query parameter is keyed by exact name "tab" — uppercase
  /// or different name should not match. Pin to detect a regression
  /// if the lookup ever flips to case-insensitive on the param NAME.
  @Test("tab= parameter NAME is case-sensitive (only lowercase 'tab' wins)")
  func settingsTabParamNameCaseSensitive() {
    let url = URL(string: "galley-settings://?TAB=server")!
    #expect(OpenSettingsActivity(from: url) == .init(nil))
  }

  @Test("Settings with no query items returns no tab")
  func settingsEmptyQuery() {
    let url = URL(string: "galley-settings://?")!
    #expect(OpenSettingsActivity(from: url) == .init(nil))
  }

  @Test("Settings with extra unrelated params still returns the tab")
  func settingsTabWithExtras() {
    let url = URL(string: "galley-settings://?foo=bar&tab=server&x=y")!
    #expect(OpenSettingsActivity(from: url) == .init(.server))
  }

  // MARK: - Unparseable cases

  @Test("galley:// with only a query and no path is unparseable")
  func emptyPathWithQueryUnparseable() {
    // host is nil and path is empty — neither settings nor a doc.
    let url = URL(string: "galley://?line=10")!
    let document = OpenDocumentActivity(from: url)
    if nil == document { /* expected */ } else {
      Issue.record("Expected .unparseable, got \(document)")
    }
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

  // MARK: - Scheme round-trips (build → parse)

  @Test("openSettings builds a galley-settings URL that parses back",
        arguments: SettingsTab.allCases)
  func settingsURLRoundTrip(tab: SettingsTab) {
    let url = OpenSettingsActivity(tab).url
    #expect(url.scheme == "galley-settings")
    #expect(OpenSettingsActivity(from: url) == .init(tab))
  }

  // MARK: - Help URL helpers

  @Test("galley-help URL round-trips to the bundle file path")
  func helpURLRoundTrip() {
    let file = URL(fileURLWithPath: "/App.app/Contents/Resources/help.md")
    let url = OpenHelpActivity(documentURL: file).url
    #expect(url.scheme == "galley-help")
    #expect(OpenHelpActivity(from: url)?.documentURL == file)
  }

  @Test("Non-help URLs have no galleyHelpFileURL")
  func nonHelpHasNoFileURL() {
    #expect(OpenHelpActivity(from: URL(string: "galley:///tmp/a.md")!) == nil)
    #expect(OpenHelpActivity(from: URL(fileURLWithPath: "/tmp/a.md")) == nil)
  }
}
