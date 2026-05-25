//
//  KosmosTunnelSchemeTests.swift
//

import Foundation
import Testing
import KosmosHTTPTunnel
@testable import GalleyCoreKit

@Suite("KosmosTunnelScheme")
struct KosmosTunnelSchemeTests {
  @Test("preview URL for a simple absolute path")
  func simplePath() throws {
    let url = try #require(TunnelScheme.originURL.galleyPreviewURL(
      forFile: "/Users/x/Documents/foo.md"))
    #expect(url.absoluteString
      == "kosmos://local/preview/Users/x/Documents/foo.md")
  }

  @Test("path segments with spaces / unicode get percent-encoded")
  func encodesPath() throws {
    let url = try #require(TunnelScheme.originURL.galleyPreviewURL(
      forFile: "/Users/x/Read Me.md"))
    #expect(url.absoluteString
      == "kosmos://local/preview/Users/x/Read%20Me.md")
  }

  @Test("relative path is rejected")
  func rejectsRelative() {
    #expect(TunnelScheme.originURL.galleyPreviewURL(forFile: "foo.md") == nil)
  }
}
