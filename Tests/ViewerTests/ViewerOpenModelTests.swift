#if os(macOS)
import Foundation
import GalleyCoreKit
import Testing
@testable import Galley

/// Pins the scroll-line stash that survived the WindowDispatcher
/// removal: `galley://path?line=N` opens stash the line keyed by URL,
/// and the soon-to-open document window consumes it exactly once.
@MainActor
@Suite("ViewerOpenModel")
struct ViewerOpenModelTests {
  @Test("Stashed scroll line is consumed once, then nil")
  func stashConsumeOnce() {
    let model = ViewerOpenModel()
    let url = URL(fileURLWithPath: "/tmp/note.md")
    model.stash(scrollLine: 42, for: url)
    #expect(model.consumePendingScrollLine(for: url) == 42)
    #expect(model.consumePendingScrollLine(for: url) == nil)
  }

  @Test("Consume is keyed by standardized path")
  func consumeKeyedByStandardizedPath() {
    let model = ViewerOpenModel()
    model.stash(scrollLine: 7, for: URL(fileURLWithPath: "/tmp/../tmp/a.md"))
    #expect(model.consumePendingScrollLine(
      for: URL(fileURLWithPath: "/tmp/a.md")) == 7)
  }

  @Test("Unknown URL consumes to nil")
  func unknownIsNil() {
    let model = ViewerOpenModel()
    #expect(model.consumePendingScrollLine(
      for: URL(fileURLWithPath: "/tmp/missing.md")) == nil)
  }

}

/// Pins the scene routing tokens to the canonical scheme constants —
/// no scattered hardcoded strings, and the document tokens must not
/// capture the settings / help schemes.
@Suite("MacScene tokens")
struct MacSceneTests {
  @Test("Scheme tokens derive from the canonical scheme constants")
  func tokensDeriveFromSchemes() {
    #expect(MacScene.settingsSchemeTokens
      == ["\(GalleyRequest.settingsScheme):"])
    #expect(MacScene.helpSchemeTokens == ["\(URL.galleyHelpScheme):"])
    #expect(MacScene.documentSchemeTokens.contains("\(GalleyRequest.scheme):"))
  }

  @Test("Document tokens do not prefix-capture settings / help schemes")
  func documentTokensExcludeOtherSchemes() {
    let settings = "\(GalleyRequest.settingsScheme):"   // "galley-settings:"
    let help = "\(URL.galleyHelpScheme):"               // "galley-help:"
    for token in MacScene.documentSchemeTokens {
      #expect(!settings.hasPrefix(token))
      #expect(!help.hasPrefix(token))
    }
  }
}
#endif
