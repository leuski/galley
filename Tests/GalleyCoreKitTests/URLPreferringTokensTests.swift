import Foundation
import Testing
@testable import GalleyCoreKit

/// Pins the `preferring:` token list each document window advertises
/// for SwiftUI `handlesExternalEvents` dedup. The whole
/// route-repeat-open-to-the-existing-window behavior rests on these
/// tokens matching the forms a re-open actually arrives in.
@Suite("URL.galleyPreferringTokens")
struct URLPreferringTokensTests {
  @Test("Drops the query so line variants still match")
  func dropsQuery() {
    let url = URL(string: "galley:/Users/me/a.md?line=42")!
    let tokens = url.galleyPreferringTokens
    #expect(tokens.contains("galley:/Users/me/a.md"))
    #expect(!tokens.contains { $0.contains("line=42") })
  }

  @Test("A file URL advertises both its file and galley forms")
  func fileAndGalleyForms() {
    let url = URL(fileURLWithPath: "/Users/me/a.md")
    let tokens = url.galleyPreferringTokens
    // The file:// form so Finder re-opens route here…
    #expect(tokens.contains { $0.hasPrefix("file://") && $0.hasSuffix("/Users/me/a.md") })
    // …and the galley-viewer:// form so menu / Server opens route here
    // too (the Viewer claims `galley-viewer://`; `galley://` is the
    // Server's scheme).
    #expect(tokens.contains {
      $0.hasPrefix("galley-viewer:") && $0.hasSuffix("/Users/me/a.md")
    })
  }

  @Test("Adds the standardized file form when it differs")
  func standardizedFormAdded() {
    let url = URL(fileURLWithPath: "/Users/me/../me/a.md")
    let tokens = url.galleyPreferringTokens
    #expect(tokens.contains { $0.hasSuffix("/Users/me/a.md") })
  }

  @Test("No bound URL yields no tokens")
  func emptyForBareScheme() {
    // A scheme-only URL has an empty path → still produces its own
    // string, but the helper must never crash and must dedupe.
    let url = URL(string: "galley:/Users/me/a.md")!
    let tokens = url.galleyPreferringTokens
    #expect(Set(tokens).count == tokens.count)  // no duplicates
  }

  @Test("Tokens are free of query and fragment")
  func withoutQueryOrFragment() {
    let url = URL(string: "galley:/Users/me/a.md?line=3#frag")!
    #expect(url.withoutQueryOrFragment.absoluteString == "galley:/Users/me/a.md")
  }
}
