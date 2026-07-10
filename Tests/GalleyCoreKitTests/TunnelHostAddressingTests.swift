//
//  TunnelHostAddressingTests.swift
//
//  The tunnel URL's host component carries the serving Server's Kosmos
//  id. The Server stamps it when routing a document to the AVP
//  (`ServerKosmosService.dispatchToClient` builds
//  `TunnelScheme.originURL(forPeer:).appending(.documentAsset(...))`),
//  and the AVP reads `documentURL.host` to address "open in editor"
//  back to the exact Mac that owns the file — no discovery, no
//  side-table. These pin that round-trip at the URL layer.
//

import Foundation
import Testing
import KosmosHTTPTunnel
@testable import GalleyCoreKit

@Suite("Tunnel host addressing")
struct TunnelHostAddressingTests {
  private let serverID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"

  @Test("Server-stamped tunnel URL exposes the server id as its host")
  func hostCarriesServerID() throws {
    let doc = URL(fileURLWithPath: "/Users/me/notes/a.md")
    let url = TunnelScheme.originURL(forPeer: serverID)
      .appending(.documentAsset(doc))
    #expect(url.scheme == TunnelScheme.name)
    #expect(url.host()?.lowercased() == serverID)
  }

  @Test("a document path with spaces still round-trips the host")
  func hostSurvivesSpacedPath() throws {
    let doc = URL(fileURLWithPath: "/Users/me/my notes/a b.md")
    let url = TunnelScheme.originURL(forPeer: serverID)
      .appending(.documentAsset(doc))
    #expect(url.host()?.lowercased() == serverID)
  }

  @Test("originURL(forPeer:) falls back to the sentinel for an illegal host")
  func fallsBackForIllegalHost() {
    #expect(
      TunnelScheme.originURL(forPeer: "not a host") == TunnelScheme.originURL)
  }
}
