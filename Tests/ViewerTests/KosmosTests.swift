//
//  KosmosTests.swift
//  Galley
//
//  Galley-specific Kosmos wire contract. The generic surface this file
//  used to re-test now lives upstream in the Kosmos package and is
//  covered there, so it was removed here:
//
//    - PeerInfo metadata extraction (kosmos.role / host) →
//      `KosmosTransportTests/KosmosMetadataTests`.
//    - `AnyMessage` envelope encode/decode/tryDecode →
//      `KosmosCoreTests/AnyMessageTests`.
//    - Two-peer InMemory loopback + request/reply →
//      `KosmosTransportTests/KosmosClientTests`.
//    - Peer *selection* (the old product-blind `GalleyPeerClassifier`,
//      now removed) → `KosmosServiceHost.presentPeer`/`reachablePeer`,
//      covered by `KosmosTransportTests/KosmosServiceHostTests`
//      ("KosmosServiceHost — peer selection").
//
//  What's left is the one thing only Galley can own: the `RouteToAVP`
//  wire-format contract. Those `messageType` strings are field
//  identifiers — once a built Server and a built Mac Viewer are
//  deployed, changing them silently breaks the "Show on Vision Pro"
//  routing path. Pin them.
//

import Foundation
import GalleyCoreKit
import KosmosCore
import Testing

@Suite("RouteToAVP wire format")
struct RouteToAVPWireFormatTests {
  @Test("messageType identifiers are the agreed strings")
  func messageTypeIdentifiers() {
    #expect(RouteToAVP.messageType == "net.leuski.galley.route-to-avp.v1")
    #expect(RouteToAVP.Reply.messageType ==
      "net.leuski.galley.route-to-avp.reply.v1")
  }

  @Test("RouteToAVP round-trips through AnyMessage")
  func routeToAVPRoundTrip() throws {
    let original = RouteToAVP(target: DocumentTarget(
      url: URL(fileURLWithPath: "/tmp/foo.md")))
    let envelope = try AnyMessage(original)
    #expect(envelope.type == RouteToAVP.messageType)
    let decoded = try envelope.decode(as: RouteToAVP.self)
    #expect(decoded == original)
  }

  @Test("RouteToAVP.Reply round-trips through AnyMessage")
  func routeToAVPReplyRoundTrip() throws {
    let original = RouteToAVP.Reply(accepted: true)
    let envelope = try AnyMessage(original)
    #expect(envelope.type == RouteToAVP.Reply.messageType)
    let decoded = try envelope.decode(as: RouteToAVP.Reply.self)
    #expect(decoded == original)
  }

  @Test("tryDecode rejects the wrong type")
  func tryDecodeMismatch() throws {
    let envelope = try AnyMessage(RouteToAVP(target: DocumentTarget(
      url: URL(fileURLWithPath: "/tmp/foo.md"))))
    let mismatch = envelope.tryDecode(as: RouteToAVP.Reply.self)
    #expect(mismatch == nil)
  }
}
