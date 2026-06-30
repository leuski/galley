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
  func simplePath() {
    let url = TunnelScheme.originURL.appending(
      .documentAsset(URL(fileURLWithPath: "/Users/x/Documents/foo.md")))
    #expect(url.absoluteString
      == "kosmos://local/preview/Users/x/Documents/foo.md")
  }

  @Test("path segments with spaces / unicode get percent-encoded")
  func encodesPath() {
    let url = TunnelScheme.originURL.appending(
      .documentAsset(URL(fileURLWithPath: "/Users/x/Read Me.md")))
    #expect(url.absoluteString
      == "kosmos://local/preview/Users/x/Read%20Me.md")
  }
}
