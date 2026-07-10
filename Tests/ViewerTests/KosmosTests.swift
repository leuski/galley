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
//  wire round-trip. `messageType` uses the default type-name identifier
//  (`String(reflecting:)`), so the contract pinned here is behavioral —
//  each type carries a distinct, non-empty envelope tag and round-trips
//  through `AnyMessage` — rather than a specific literal string.
//

import Foundation
import GalleyCoreKit
import KosmosCore
import Testing

@Suite("RouteToAVP wire format")
struct RouteToAVPWireFormatTests {
  @Test("RouteToAVP and its Reply carry distinct, non-empty message types")
  func messageTypesAreDistinct() {
    // Type-name identifiers (`String(reflecting:)`), not pinned literals.
    // The invariant that matters is that request and reply route to
    // different envelope tags, so a reply is never mistaken for a request.
    #expect(!RouteToAVP.messageType.isEmpty)
    #expect(!RouteToAVP.Reply.messageType.isEmpty)
    #expect(RouteToAVP.messageType != RouteToAVP.Reply.messageType)
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
