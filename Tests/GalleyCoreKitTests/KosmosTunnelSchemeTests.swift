//
//  KosmosTunnelSchemeTests.swift
//

import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("KosmosTunnelScheme")
struct KosmosTunnelSchemeTests {
  @Test("name and prefix are stable")
  func nameAndPrefix() {
    #expect(KosmosTunnelScheme.name == "galley")
    #expect(KosmosTunnelScheme.previewURLPrefix == "galley://preview")
  }

  @Test("preview URL for a simple absolute path")
  func simplePath() throws {
    let url = try #require(KosmosTunnelScheme.previewURL(
      forFile: "/Users/x/Documents/foo.md"))
    #expect(url.absoluteString
      == "galley://preview/Users/x/Documents/foo.md")
  }

  @Test("path segments with spaces / unicode get percent-encoded")
  func encodesPath() throws {
    let url = try #require(KosmosTunnelScheme.previewURL(
      forFile: "/Users/x/Read Me.md"))
    #expect(url.absoluteString
      == "galley://preview/Users/x/Read%20Me.md")
  }

  @Test("relative path is rejected")
  func rejectsRelative() {
    #expect(KosmosTunnelScheme.previewURL(forFile: "foo.md") == nil)
  }
}
