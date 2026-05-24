import Foundation
import Testing
@testable import GalleyCoreKit

// Test-exempt edits to KosmosLink.swift made on this date:
// - 2026-05-23: precomputed lanHost / httpsPort locals before
//   os.Logger interpolation (line-continuations inside `\(...)` don't
//   parse). Pure syntactic fix; no behavior change; no new test.
// - 2026-05-23: split dispatchOpenURLToAVP into private helpers to
//   stay under the SwiftLint function_body_length cap. Pure
//   extraction; same callers, same observable behavior; BridgeURL-
//   BuilderTests already pin the URL-construction policy.
//
// Test-exempt edits to PreviewServer.swift made on this date:
// - 2026-05-23: added diagnostic log lines to disambiguate which exit
//   path the HTTPS run Task took (cancellation, error, or normal
//   return). Pure log additions to narrow the silent-clear failure
//   mode where the HTTPS port file disappears without an error event.
// - 2026-05-23: stopped the HTTPS run Task from unconditionally
//   clearing the port file. Clear only on the explicit error / catch
//   paths (and from `stop()`). Strong-inference fix for the
//   observed-but-unreproducible silent-clear bug; the diagnostic logs
//   above will surface the actual `app.run()` exit path next time it
//   trips. No unit test feasible without driving a real
//   Hummingbird+TLS bind from the test harness.

/// Records each `(scheme, host, port)` the builder asked it to compose,
/// and returns a deterministic URL so assertions are exact. Decouples
/// the builder's policy decisions from `LANHostDiscovery`'s IPv6
/// bracketing.
private final class RecordingComposer {
  private(set) var calls: [(scheme: String, host: String, port: UInt16)] = []

  var compose: BridgeURLBuilder.Composer {
    { [weak self] scheme, host, port in
      self?.calls.append((scheme, host, port))
      var c = URLComponents()
      c.scheme = scheme
      c.host = host
      c.port = Int(port)
      return c.url
    }
  }
}

@Suite("BridgeURLBuilder.preferredAVPHost")
struct BridgeURLBuilderPreferredAVPHostTests {
  /// AWDL link-local is the only path that works in both "AVP on the
  /// same AP" and "AVP on AWDL only" states, so it's always the right
  /// pick when present. Symbol the canonical case: full candidate list
  /// as returned by `LANHostDiscovery.reachableHosts()` on a Mac with
  /// both Bonjour name and AWDL alive.
  @Test("AWDL link-local is preferred over Bonjour hostname")
  func awdlBeatsBonjour() {
    let candidates = [
      "mercury.local",
      "fe80::7ce9:95ff:fe6d:a88a%awdl0",
      "fe80::1cd1:f26b:c7:295a%en0",
      "192.168.2.146",
    ]
    let host = BridgeURLBuilder.preferredAVPHost(from: candidates)
    #expect(host == "fe80::7ce9:95ff:fe6d:a88a%awdl0")
  }

  /// AWDL match is case-insensitive (host strings come from system
  /// formatters that might normalize differently).
  @Test("AWDL zone match is case-insensitive")
  func awdlCaseInsensitive() {
    let host = BridgeURLBuilder.preferredAVPHost(
      from: ["mercury.local", "fe80::1%AWDL0"])
    #expect(host == "fe80::1%AWDL0")
  }

  /// No AWDL in the list — fall back to the first candidate. On a
  /// shared infrastructure Wi-Fi this gives us `mercury.local`, which
  /// AVP can resolve via standard mDNS.
  @Test("No AWDL host → falls back to first candidate")
  func fallbackToFirst() {
    let candidates = ["mercury.local", "192.168.2.146"]
    let host = BridgeURLBuilder.preferredAVPHost(from: candidates)
    #expect(host == "mercury.local")
  }

  /// Multiple IPv6 link-locals with different zone IDs — `%awdl0`
  /// specifically wins, not just "any link-local".
  @Test("Other link-local zones are not treated as AWDL")
  func nonAWDLLinkLocalRejected() {
    let candidates = [
      "fe80::1cd1:f26b:c7:295a%en0",
      "fe80::7ce9:95ff:fe6d:a88a%awdl0",
    ]
    let host = BridgeURLBuilder.preferredAVPHost(from: candidates)
    #expect(host == "fe80::7ce9:95ff:fe6d:a88a%awdl0")
  }

  @Test("Empty list → nil")
  func emptyList() {
    #expect(BridgeURLBuilder.preferredAVPHost(from: []) == nil)
  }
}

@Suite("BridgeURLBuilder.avpDocumentURL")
struct BridgeURLBuilderAVPDocumentURLTests {
  @Test("HTTPS port + host → HTTPS URL on the HTTPS port")
  func httpsPresent() {
    let recorder = RecordingComposer()
    let url = BridgeURLBuilder.avpDocumentURL(
      host: "mercury.local",
      httpsPort: 57772,
      compose: recorder.compose)
    #expect(url?.absoluteString == "https://mercury.local:57772")
    #expect(recorder.calls.count == 1)
    #expect(recorder.calls.first?.scheme == "https")
  }

  /// The bug today — HTTPS listener silently failed to bind on `::`,
  /// so the HTTPS port file was missing. The old `lanBaseURL` fell
  /// back to HTTP, producing `http://mercury.local:<loopback-port>/`.
  /// AVP can't reach that — the HTTP listener is loopback-only by
  /// design. The builder must refuse to dispatch instead.
  @Test("HTTPS port missing → nil, even when HTTP port is present")
  func httpsMissingNeverFallsBack() {
    let recorder = RecordingComposer()
    let url = BridgeURLBuilder.avpDocumentURL(
      host: "mercury.local",
      httpsPort: nil,
      compose: recorder.compose)
    #expect(url == nil)
    #expect(recorder.calls.isEmpty, "compose must not be invoked")
  }

  @Test("Host missing → nil regardless of port")
  func hostMissing() {
    let url = BridgeURLBuilder.avpDocumentURL(
      host: nil,
      httpsPort: 57772,
      compose: RecordingComposer().compose)
    #expect(url == nil)
  }

  @Test("IPv6 host is passed through to the composer verbatim")
  func ipv6Passthrough() {
    let recorder = RecordingComposer()
    _ = BridgeURLBuilder.avpDocumentURL(
      host: "fe80::1%awdl0",
      httpsPort: 4443,
      compose: recorder.compose)
    #expect(recorder.calls.first?.host == "fe80::1%awdl0")
    #expect(recorder.calls.first?.port == 4443)
  }
}

@Suite("BridgeURLBuilder.advertisementURL")
struct BridgeURLBuilderAdvertisementURLTests {
  @Test("HTTPS preferred when both ports are present")
  func httpsPreferred() {
    let recorder = RecordingComposer()
    let url = BridgeURLBuilder.advertisementURL(
      host: "mercury.local",
      httpPort: 57127,
      httpsPort: 57772,
      compose: recorder.compose)
    #expect(url?.absoluteString == "https://mercury.local:57772")
    #expect(recorder.calls.first?.scheme == "https")
  }

  @Test("HTTPS missing → falls back to HTTP for advertisement only")
  func httpFallback() {
    let recorder = RecordingComposer()
    let url = BridgeURLBuilder.advertisementURL(
      host: "mercury.local",
      httpPort: 57127,
      httpsPort: nil,
      compose: recorder.compose)
    #expect(url?.absoluteString == "http://mercury.local:57127")
    #expect(recorder.calls.first?.scheme == "http")
  }

  @Test("Both ports missing → nil")
  func bothMissing() {
    let url = BridgeURLBuilder.advertisementURL(
      host: "mercury.local",
      httpPort: nil,
      httpsPort: nil,
      compose: RecordingComposer().compose)
    #expect(url == nil)
  }

  @Test("Host missing → nil regardless of ports")
  func hostMissing() {
    let url = BridgeURLBuilder.advertisementURL(
      host: nil,
      httpPort: 57127,
      httpsPort: 57772,
      compose: RecordingComposer().compose)
    #expect(url == nil)
  }
}
