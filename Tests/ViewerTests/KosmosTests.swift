//
//  KosmosTests.swift
//  Galley
//
//  Tests for the Galley Kosmos surface: peer metadata classification,
//  RouteToAVP wire-format stability, and a two-link InMemory loopback
//  exercising the same request/reply path the real (LoomKosmosLink-
//  backed) Mac Viewer → Server roundtrip uses on the wire. The
//  integration test is in-process and doesn't need Bonjour — failures
//  there indicate a regression in our wire contract, not in network
//  reachability.
//
//  `GalleyKosmos.swift` lives in `GalleyCoreKit` and is public;
//  `KosmosViewerService.swift` is internal to the Viewer module, so
//  the `@testable import Galley` stays for the host-side surface.
//

import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosTransport
import Testing
@testable import Galley

// MARK: - PeerInfo metadata extraction

@Suite("PeerInfo galley metadata")
struct PeerInfoMetadataTests {
  @Test("galleyRole reads the role key")
  func galleyRoleReadsKey() {
    let info = PeerInfo(
      id: PeerID("abc"),
      metadata: ["kosmos.role": "server"])
    #expect(info.galleyRole == .server)
  }

  @Test("galleyRole returns nil for missing role")
  func galleyRoleMissing() {
    let info = PeerInfo(id: PeerID("abc"), metadata: [:])
    #expect(info.galleyRole == nil)
  }

  @Test("galleyRole returns nil for unknown role value")
  func galleyRoleUnknown() {
    let info = PeerInfo(
      id: PeerID("abc"),
      metadata: ["kosmos.role": "phantom"])
    #expect(info.galleyRole == nil)
  }

  @Test("All three Galley roles round-trip through metadata")
  func allRolesRoundTrip() {
    for role in [
      GalleyKosmosRole.server,
      .macViewer,
      .visionViewer
    ] {
      let info = PeerInfo(
        id: PeerID("abc"),
        metadata: ["kosmos.role": role.rawValue])
      #expect(info.galleyRole == role)
    }
  }

  @Test("hostUUID reads the host key")
  func galleyHostReadsKey() {
    let info = PeerInfo(
      id: PeerID("abc"),
      metadata: ["kosmos.host": "HOST-UUID"])
    #expect(info.hostUUID == "HOST-UUID")
  }

  @Test("hostUUID nil when absent")
  func galleyHostMissing() {
    let info = PeerInfo(id: PeerID("abc"), metadata: [:])
    #expect(info.hostUUID == nil)
  }
}

// MARK: - Peer classifier (the Mac Viewer's pill / menu logic)

@Suite("GalleyPeerClassifier")
struct GalleyPeerClassifierTests {
  private let localHost = "this-mac-uuid"

  private func makePeer(
    _ id: String,
    role: GalleyKosmosRole?,
    host: String? = nil
  ) -> PeerInfo {
    var metadata: [String: String] = [:]
    if let role { metadata["kosmos.role"] = role.rawValue }
    if let host { metadata["kosmos.host"] = host }
    return PeerInfo(id: PeerID(id), metadata: metadata)
  }

  private func peerSet(_ infos: PeerInfo...) -> [PeerID: PeerInfo] {
    Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
  }

  @Test("serverPeer is nil when the peer set is empty")
  func serverPeerEmpty() {
    let result = GalleyPeerClassifier.serverPeer(
      in: [:], localHostUUID: localHost)
    #expect(result == nil)
  }

  @Test("serverPeer picks a same-host Server")
  func serverPeerSameHost() {
    let server = makePeer("S1", role: .server, host: localHost)
    let viewer = makePeer("V1", role: .macViewer, host: localHost)
    let result = GalleyPeerClassifier.serverPeer(
      in: peerSet(server, viewer), localHostUUID: localHost)
    #expect(result == PeerID("S1"))
  }

  @Test("serverPeer ignores a Server on a different Mac")
  func serverPeerOtherHost() {
    let other = makePeer("S2", role: .server, host: "other-mac")
    let result = GalleyPeerClassifier.serverPeer(
      in: peerSet(other), localHostUUID: localHost)
    #expect(result == nil, """
      Server peers tagged with a different host UUID must be skipped \
      so the Mac Viewer doesn't pair with a coworker's Server on the \
      same _kosmos._tcp network.
      """)
  }

  @Test("serverPeer accepts a host-tagged Server when local host is nil")
  func serverPeerLocalHostNil() {
    // visionOS slice (no gethostuuid): any Server wins. Validates the
    // last-resort branch in serverPeer.
    let server = makePeer("S1", role: .server, host: "any-mac")
    let result = GalleyPeerClassifier.serverPeer(
      in: peerSet(server), localHostUUID: nil)
    #expect(result == PeerID("S1"))
  }

  @Test("serverPeer accepts an untagged Server (legacy / no host info)")
  func serverPeerNoHostMetadata() {
    // A Server that didn't publish kosmos.host (older build, or
    // gethostuuid failure). We accept it rather than refuse outright.
    let server = makePeer("S1", role: .server, host: nil)
    let result = GalleyPeerClassifier.serverPeer(
      in: peerSet(server), localHostUUID: localHost)
    #expect(result == PeerID("S1"))
  }

  @Test("serverPeer ignores macViewer / visionViewer peers")
  func serverPeerIgnoresNonServer() {
    let viewer = makePeer("V1", role: .macViewer, host: localHost)
    let avp = makePeer("A1", role: .visionViewer, host: localHost)
    let result = GalleyPeerClassifier.serverPeer(
      in: peerSet(viewer, avp), localHostUUID: localHost)
    #expect(result == nil)
  }

  @Test("avpPeer picks a visionViewer peer regardless of host")
  func avpPeerPicksVision() {
    let avp = makePeer("A1", role: .visionViewer, host: "different")
    let server = makePeer("S1", role: .server, host: localHost)
    let result = GalleyPeerClassifier.avpPeer(
      in: peerSet(server, avp))
    #expect(result == PeerID("A1"))
  }

  @Test("avpPeer is nil when no visionViewer present")
  func avpPeerNone() {
    let server = makePeer("S1", role: .server, host: localHost)
    let result = GalleyPeerClassifier.avpPeer(in: peerSet(server))
    #expect(result == nil)
  }
}

// MARK: - RouteToAVP wire format

/// `messageType` strings are wire identifiers — once a built Server and
/// a built Mac Viewer are in the field, changing these silently breaks
/// the routing path. Pin them.
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

// MARK: - Two-peer InMemory loopback

/// Drives two `KosmosClient`s against a shared `InMemoryKosmosNetwork`,
/// the same surface `LoomKosmosLink` presents in production. Verifies
/// the end-to-end RouteToAVP request/reply path the Mac Viewer ↔
/// Server pair uses on the wire, without needing Bonjour / Loom /
/// keychain identities. A regression here means the message contract
/// is broken; a passing test plus a failing real-world connection
/// means the failure is in network reachability (Local Network
/// permission, firewall, mDNSResponder trust DB) rather than the
/// Galley code.
@Suite("Kosmos inter-peer loopback")
struct KosmosLoopbackTests {

  /// Identity for a Galley peer with the same metadata shape Galley
  /// publishes in production.
  private static func make(
    role: GalleyKosmosRole,
    id: String,
    host: String? = nil
  ) -> (PeerID, [String: String]) {
    var metadata: [String: String] = [
      "kosmos.role": role.rawValue,
      "kosmos.product": "galley"
    ]
    if let host { metadata["kosmos.host"] = host }
    return (PeerID(id), metadata)
  }

  @Test("Mac Viewer ↔ Server discover each other via metadata")
  func twoPeersDiscoverViaMetadata() async throws {
    let network = InMemoryKosmosNetwork()
    let (serverID, serverMeta) = Self.make(
      role: .server, id: "server-1", host: "macA")
    let (viewerID, viewerMeta) = Self.make(
      role: .macViewer, id: "viewer-1", host: "macA")

    let serverLink = InMemoryKosmosLink(
      identity: serverID, network: network, metadata: serverMeta)
    let viewerLink = InMemoryKosmosLink(
      identity: viewerID, network: network, metadata: viewerMeta)
    let serverClient = KosmosClient(identity: serverID, link: serverLink)
    let viewerClient = KosmosClient(identity: viewerID, link: viewerLink)
    await serverClient.start()
    await viewerClient.start()

    // Race-free observation: collect the first non-empty snapshot.
    let viewerPeers = viewerClient.peers
    async let observed: [PeerID: PeerInfo] = {
      for await snapshot in viewerPeers where !snapshot.isEmpty {
        return snapshot
      }
      return [:]
    }()

    await network.register(serverLink)
    await network.register(viewerLink)

    let snapshot = await observed
    #expect(snapshot[serverID]?.galleyRole == .server)
    #expect(snapshot[serverID]?.hostUUID == "macA")

    // Same-host classification (the production pill / menu wiring).
    #expect(GalleyPeerClassifier.serverPeer(
      in: snapshot, localHostUUID: "macA") == serverID)

    await serverClient.stop()
    await viewerClient.stop()
  }

  @Test("RouteToAVP request/reply round-trips between peers")
  func routeToAVPRequestReply() async throws {
    let network = InMemoryKosmosNetwork()
    let (serverID, serverMeta) = Self.make(
      role: .server, id: "server-rr", host: "macA")
    let (viewerID, viewerMeta) = Self.make(
      role: .macViewer, id: "viewer-rr", host: "macA")

    let serverLink = InMemoryKosmosLink(
      identity: serverID, network: network, metadata: serverMeta)
    let viewerLink = InMemoryKosmosLink(
      identity: viewerID, network: network, metadata: viewerMeta)
    let serverClient = KosmosClient(identity: serverID, link: serverLink)
    let viewerClient = KosmosClient(identity: viewerID, link: viewerLink)

    // Capture what the Server received so we can assert the wire
    // payload survives the round-trip.
    let received = Locked<String?>(nil)
    await serverClient.handle(
      RouteToAVP.self
    ) { _, request -> RouteToAVP.Reply in
      received.set(request.target.url.path)
      return RouteToAVP.Reply(accepted: true)
    }

    await serverClient.start()
    await viewerClient.start()
    await network.register(serverLink)
    await network.register(viewerLink)

    let reply = try await viewerClient.send(
      RouteToAVP(target: DocumentTarget(
        url: URL(fileURLWithPath: "/Users/test/Doc.md"))),
      to: serverID,
      replyType: RouteToAVP.Reply.self)

    #expect(reply.accepted)
    #expect(received.value == "/Users/test/Doc.md")

    await serverClient.stop()
    await viewerClient.stop()
  }

  @Test("Mac Viewer's serverPeer / avpPeer reflect the live peer set")
  func macViewerPeerAccessors() async throws {
    let network = InMemoryKosmosNetwork()
    let (serverID, serverMeta) = Self.make(
      role: .server, id: "S", host: "macA")
    let (avpID, avpMeta) = Self.make(
      role: .visionViewer, id: "A", host: "AVP")
    let (viewerID, viewerMeta) = Self.make(
      role: .macViewer, id: "V", host: "macA")

    let serverLink = InMemoryKosmosLink(
      identity: serverID, network: network, metadata: serverMeta)
    let avpLink = InMemoryKosmosLink(
      identity: avpID, network: network, metadata: avpMeta)
    let viewerLink = InMemoryKosmosLink(
      identity: viewerID, network: network, metadata: viewerMeta)

    let viewerClient = KosmosClient(identity: viewerID, link: viewerLink)
    await viewerClient.start()

    let viewerPeers = viewerClient.peers
    async let observed: [PeerID: PeerInfo] = {
      for await snapshot in viewerPeers where snapshot.count >= 2 {
        return snapshot
      }
      return [:]
    }()

    await network.register(serverLink)
    await network.register(avpLink)
    await network.register(viewerLink)

    let snapshot = await observed
    #expect(GalleyPeerClassifier.serverPeer(
      in: snapshot, localHostUUID: "macA") == serverID)
    #expect(GalleyPeerClassifier.avpPeer(in: snapshot) == avpID)

    await viewerClient.stop()
  }
}

// MARK: - Helpers

/// Tiny thread-safe box for closure-captured assertions in async
/// tests. Avoids pulling NIO's Locked or building a custom actor.
private final class Locked<Value>: @unchecked Sendable {
  private var storage: Value
  private let lock = NSLock()
  init(_ initial: Value) { storage = initial }
  var value: Value {
    lock.lock(); defer { lock.unlock() }
    return storage
  }
  func set(_ newValue: Value) {
    lock.lock(); defer { lock.unlock() }
    storage = newValue
  }
}
