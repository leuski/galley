import Foundation
import Testing
@testable import GalleyCoreKit
internal import ALFoundation

/// Exercises the on-disk handshake between Galley Server (writer)
/// and its consumers (readers — Viewer probe, Quicklook, BBEdit
/// browser scripts). Touches the real files at
/// `~/Library/Application Support/net.leuski.galley.localized/
/// server-<scheme>-port`,
/// so the suite is serialized and snapshots each file on entry /
/// restores on exit, to avoid clobbering a running Server.
@Suite("ServerPortFile", .serialized)
struct ServerPortFileTests {
  /// Snapshot any pre-existing values for every file so a running
  /// Server's ports survive the test run.
  private static func snapshot() -> [ServerPortFile: Data] {
    var result: [ServerPortFile: Data] = [:]
    for file in ServerPortFile.all {
      if let data = try? Data(contentsOf: file.url) {
        result[file] = data
      }
    }
    return result
  }

  private static func restore(_ snapshot: [ServerPortFile: Data]) {
    for file in ServerPortFile.all {
      if let data = snapshot[file] {
        try? data.write(to: file.url)
      } else {
        file.clear()
      }
    }
  }

  @Test("write then read round-trips per scheme", arguments: [
    ServerPortFile.http, .https
  ])
  func roundTrip(file: ServerPortFile) throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try file.write(54321)
    #expect(file.read() == 54321)
  }

  @Test("clear removes the file; read returns nil")
  func clearMakesReadNil() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try ServerPortFile.http.write(12345)
    ServerPortFile.http.clear()
    #expect(ServerPortFile.http.read() == nil)
  }

  @Test("scheme files are independent")
  func schemesAreIndependent() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.http.clear()
    ServerPortFile.https.clear()
    try ServerPortFile.http.write(11111)
    #expect(ServerPortFile.http.read() == 11111)
    #expect(ServerPortFile.https.read() == nil)
  }

  @Test("malformed file reads as nil, not a crash")
  func malformedFileReadsAsNil() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try GalleyConstants.applicationSupportDirectory.createDirectory()
    try "not-a-port\n".write(
      to: ServerPortFile.http.url,
      atomically: true,
      encoding: .utf8)
    #expect(ServerPortFile.http.read() == nil)
  }

  @Test("endpointURL builds scheme://127.0.0.1:<port>/ from the file")
  func endpointURLReflectsFile() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try ServerPortFile.http.write(60000)
    let url = ServerPortFile.http.endpointURL
    #expect(url?.scheme == "http")
    #expect(url?.host == "127.0.0.1")
    #expect(url?.port == 60000)

    try ServerPortFile.https.write(60443)
    let secure = ServerPortFile.https.endpointURL
    #expect(secure?.scheme == "https")
    #expect(secure?.port == 60443)
  }

  @Test("endpointURL is nil when the file is missing")
  func endpointURLNilWhenMissing() {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.http.clear()
    #expect(ServerPortFile.http.endpointURL == nil)
  }

  @Test("preferredEndpointURL picks HTTP when both are present")
  func preferredPicksHTTP() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    try ServerPortFile.http.write(20000)
    try ServerPortFile.https.write(20443)
    #expect(ServerPortFile.preferredEndpointURL?.scheme == "http")
    #expect(ServerPortFile.preferredEndpointURL?.port == 20000)
  }

  @Test("preferredEndpointURL falls back to HTTPS when HTTP is absent")
  func preferredFallsBack() throws {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.http.clear()
    try ServerPortFile.https.write(20443)
    #expect(ServerPortFile.preferredEndpointURL?.scheme == "https")
    #expect(ServerPortFile.preferredEndpointURL?.port == 20443)
  }

  @Test("preferredEndpointURL is nil when neither file exists")
  func preferredNilWhenNeither() {
    let snap = Self.snapshot()
    defer { Self.restore(snap) }

    ServerPortFile.http.clear()
    ServerPortFile.https.clear()
    #expect(ServerPortFile.preferredEndpointURL == nil)
  }
}
