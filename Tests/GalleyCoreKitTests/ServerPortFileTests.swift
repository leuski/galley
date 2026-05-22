import Foundation
import Testing
@testable import GalleyCoreKit
internal import ALFoundation

/// Exercises the on-disk handshake between Galley Server (writer)
/// and its consumers (readers — Viewer probe, Quicklook, BBEdit
/// browser scripts). Touches the real files at
/// `~/Library/Application Support/net.leuski.galley.localized/
/// server-<scheme>-port`,
/// so the suite is serialized and snapshots each scheme's file on
/// entry / restores on exit, to avoid clobbering a running Server.
@Suite("ServerPortFile", .serialized)
struct ServerPortFileTests {
  /// Snapshot any pre-existing values for every scheme so a running
  /// Server's ports survive the test run.
  private static func snapshot() -> [ServerPortFile.Scheme: Data] {
    var result: [ServerPortFile.Scheme: Data] = [:]
    for scheme in ServerPortFile.Scheme.allCases {
      if let data = try? Data(contentsOf: ServerPortFile.url(for: scheme)) {
        result[scheme] = data
      }
    }
    return result
  }

  private static func restore(_ snapshot: [ServerPortFile.Scheme: Data]) {
    for scheme in ServerPortFile.Scheme.allCases {
      if let data = snapshot[scheme] {
        try? data.write(to: ServerPortFile.url(for: scheme))
      } else {
        ServerPortFile.clear(for: scheme)
      }
    }
  }

  @Test("write then read round-trips per scheme", arguments: [
    ServerPortFile.Scheme.http, .https
  ])
  func roundTrip(scheme: ServerPortFile.Scheme) throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try ServerPortFile.write(54321, for: scheme)
    #expect(ServerPortFile.read(for: scheme) == 54321)
  }

  @Test("clear removes the file; read returns nil")
  func clearMakesReadNil() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try ServerPortFile.write(12345, for: .http)
    ServerPortFile.clear(for: .http)
    #expect(ServerPortFile.read(for: .http) == nil)
  }

  @Test("scheme files are independent")
  func schemesAreIndependent() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.clear(for: .http)
    ServerPortFile.clear(for: .https)
    try ServerPortFile.write(11111, for: .http)
    #expect(ServerPortFile.read(for: .http) == 11111)
    #expect(ServerPortFile.read(for: .https) == nil)
  }

  @Test("malformed file reads as nil, not a crash")
  func malformedFileReadsAsNil() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try GalleyConstants.applicationSupportDirectory.createDirectory()
    try "not-a-port\n".write(
      to: ServerPortFile.url(for: .http),
      atomically: true,
      encoding: .utf8)
    #expect(ServerPortFile.read(for: .http) == nil)
  }

  @Test("endpointURL builds scheme://127.0.0.1:<port>/ from the file")
  func endpointURLReflectsFile() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try ServerPortFile.write(60000, for: .http)
    let url = ServerPortFile.endpointURL(for: .http)
    #expect(url?.scheme == "http")
    #expect(url?.host == "127.0.0.1")
    #expect(url?.port == 60000)

    try ServerPortFile.write(60443, for: .https)
    let secure = ServerPortFile.endpointURL(for: .https)
    #expect(secure?.scheme == "https")
    #expect(secure?.port == 60443)
  }

  @Test("endpointURL is nil when the file is missing")
  func endpointURLNilWhenMissing() {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.clear(for: .http)
    #expect(ServerPortFile.endpointURL(for: .http) == nil)
  }

  @Test("preferredEndpointURL picks HTTPS when both are present")
  func preferredPicksHTTPS() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try ServerPortFile.write(20000, for: .http)
    try ServerPortFile.write(20443, for: .https)
    #expect(ServerPortFile.preferredEndpointURL?.scheme == "https")
    #expect(ServerPortFile.preferredEndpointURL?.port == 20443)
  }

  @Test("preferredEndpointURL falls back to HTTP when HTTPS is absent")
  func preferredFallsBack() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.clear(for: .https)
    try ServerPortFile.write(20000, for: .http)
    #expect(ServerPortFile.preferredEndpointURL?.scheme == "http")
    #expect(ServerPortFile.preferredEndpointURL?.port == 20000)
  }

  @Test("preferredEndpointURL is nil when neither file exists")
  func preferredNilWhenNeither() {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.clear(for: .http)
    ServerPortFile.clear(for: .https)
    #expect(ServerPortFile.preferredEndpointURL == nil)
  }
}
