//
//  AVPHTTPProxyTests.swift
//  Galley — visionOS slice
//
//  Pure-helper tests for the loopback HTTP proxy that fronts the
//  Mac-hosted preview server. Live socket + TLS behavior is deferred
//  to manual on-device verification — what we pin here is the part
//  that's deterministic and on the path of every request:
//
//   - request-header rewrite preserves the request line and all
//     non-`Host`/`Connection` headers verbatim;
//   - the rewritten `Host` carries the AWDL zone re-encoded as `%25`
//     per RFC 6874 (which is the form the Mac Server's
//     `isHostAllowed` parser expects);
//   - `Connection: close` is forced (one upstream request per inbound
//     connection — keeps the framing trivial);
//   - URL rewrite preserves path, query, and fragment verbatim and
//     swaps scheme/host/port to loopback;
//   - the host-parser turns AWDL-zoned IPv6 strings into
//     `NWEndpoint.Host.ipv6` with a scope id (the bit that makes the
//     upstream `NWConnection` actually dial the right interface).
//

#if os(visionOS)
import Foundation
import Network
import Testing

@testable import Galley

@Suite("AVPHTTPProxy header rewrite")
struct AVPHTTPProxyHeaderRewriteTests {
  private static let upstream = AVPHTTPProxy.Upstream(
    host: "fe80::aabb:ccdd:eeff:0011%awdl0",
    port: 8443,
    certSHA256: Data(repeating: 0, count: 32))

  @Test("rewrites Host with %25-encoded zone id")
  func rewritesHostWithZone() throws {
    let request = """
      GET /preview/foo.md HTTP/1.1\r\n\
      Host: 127.0.0.1:9999\r\n\
      Accept: text/html\r\n\
      \r\n
      """
    let rewritten = AVPHTTPProxy.rewriteRequestHeaders(
      Data(request.utf8), upstream: Self.upstream, proxyPort: 54290)
    let text = try #require(String(data: rewritten, encoding: .utf8))
    #expect(text.contains(
      "Host: [fe80::aabb:ccdd:eeff:0011%25awdl0]:8443"))
    #expect(!text.contains("Host: 127.0.0.1:9999"))
  }

  @Test("forces Connection: close")
  func forcesConnectionClose() throws {
    let request = """
      GET / HTTP/1.1\r\n\
      Host: example\r\n\
      Connection: keep-alive\r\n\
      \r\n
      """
    let rewritten = AVPHTTPProxy.rewriteRequestHeaders(
      Data(request.utf8), upstream: Self.upstream, proxyPort: 54290)
    let text = try #require(String(data: rewritten, encoding: .utf8))
    #expect(text.contains("Connection: close"))
    #expect(!text.contains("Connection: keep-alive"))
  }

  @Test("preserves the request line and other headers")
  func preservesRequestLineAndOtherHeaders() throws {
    let request = """
      GET /preview/sub%20dir/foo.md?x=1 HTTP/1.1\r\n\
      Host: irrelevant\r\n\
      Accept: text/html\r\n\
      Accept-Language: en\r\n\
      User-Agent: WebKit/000\r\n\
      \r\n
      """
    let rewritten = AVPHTTPProxy.rewriteRequestHeaders(
      Data(request.utf8), upstream: Self.upstream, proxyPort: 54290)
    let text = try #require(String(data: rewritten, encoding: .utf8))
    #expect(text.hasPrefix(
      "GET /preview/sub%20dir/foo.md?x=1 HTTP/1.1\r\n"))
    #expect(text.contains("Accept: text/html"))
    #expect(text.contains("Accept-Language: en"))
    #expect(text.contains("User-Agent: WebKit/000"))
    #expect(text.hasSuffix("\r\n\r\n"))
  }

  @Test("injects Host and Connection when absent")
  func injectsMissingHeaders() throws {
    // Malformed-but-legal: no Host, no Connection. We still want both
    // to land in the upstream so the Server's host-header guard and
    // our framing assumption hold.
    let request = "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n"
    let rewritten = AVPHTTPProxy.rewriteRequestHeaders(
      Data(request.utf8), upstream: Self.upstream, proxyPort: 54290)
    let text = try #require(String(data: rewritten, encoding: .utf8))
    #expect(text.contains(
      "Host: [fe80::aabb:ccdd:eeff:0011%25awdl0]:8443"))
    #expect(text.contains("Connection: close"))
    #expect(text.hasSuffix("\r\n\r\n"))
  }

  @Test("non-IPv6 host omits brackets")
  func nonIPv6HostOmitsBrackets() {
    let upstream = AVPHTTPProxy.Upstream(
      host: "my-mac.local", port: 8443,
      certSHA256: Data(repeating: 0, count: 32))
    #expect(AVPHTTPProxy.formatHostHeader(upstream)
      == "my-mac.local:8443")
  }

  @Test("non-zoned IPv6 host brackets without %25")
  func nonZonedIPv6Brackets() {
    let upstream = AVPHTTPProxy.Upstream(
      host: "2001:db8::1", port: 8443,
      certSHA256: Data(repeating: 0, count: 32))
    #expect(AVPHTTPProxy.formatHostHeader(upstream)
      == "[2001:db8::1]:8443")
  }

  @Test("injects X-Galley-Origin pointing at loopback proxy port")
  func injectsOriginHeader() throws {
    let request = """
      GET /preview/foo.md HTTP/1.1\r\n\
      Host: 127.0.0.1:9999\r\n\
      \r\n
      """
    let rewritten = AVPHTTPProxy.rewriteRequestHeaders(
      Data(request.utf8), upstream: Self.upstream, proxyPort: 54290)
    let text = try #require(String(data: rewritten, encoding: .utf8))
    #expect(text.contains(
      "X-Galley-Origin: http://127.0.0.1:54290/"))
  }

  @Test("replaces any inbound X-Galley-Origin instead of duplicating")
  func replacesInboundOriginHeader() throws {
    // WebKit doesn't send this header, but a malicious upstream could
    // attempt to inject one. The proxy must always overwrite, never
    // pass through.
    let request = """
      GET / HTTP/1.1\r\n\
      Host: irrelevant\r\n\
      X-Galley-Origin: https://attacker.example/\r\n\
      \r\n
      """
    let rewritten = AVPHTTPProxy.rewriteRequestHeaders(
      Data(request.utf8), upstream: Self.upstream, proxyPort: 54290)
    let text = try #require(String(data: rewritten, encoding: .utf8))
    #expect(text.contains(
      "X-Galley-Origin: http://127.0.0.1:54290/"))
    #expect(!text.contains("attacker.example"))
  }

  @Test("X-Galley-Origin formatter")
  func originFormatter() {
    #expect(AVPHTTPProxy.formatOriginHeader(54290)
      == "http://127.0.0.1:54290/")
  }
}

@Suite("AVPHTTPProxy host parsing")
struct AVPHTTPProxyHostParsingTests {
  @Test("AWDL-zoned IPv6 parses with scope id")
  func awdlZonedIPv6() throws {
    let host = AVPHTTPProxy.parseHost("fe80::1%awdl0")
    guard case .ipv6(let ipv6) = host else {
      Issue.record("expected .ipv6 case, got \(host)")
      return
    }
    // `IPv6Address` records the zone via a non-zero scope id when the
    // host string carries a `%<zone>` suffix.
    #expect(ipv6.debugDescription.contains("%awdl0"))
  }

  @Test("plain IPv6 has no zone")
  func plainIPv6() throws {
    let host = AVPHTTPProxy.parseHost("2001:db8::1")
    guard case .ipv6(let ipv6) = host else {
      Issue.record("expected .ipv6 case, got \(host)")
      return
    }
    #expect(!ipv6.debugDescription.contains("%"))
  }

  @Test("IPv4 dotted-quad parses as .ipv4")
  func ipv4Parses() {
    let host = AVPHTTPProxy.parseHost("192.0.2.1")
    if case .ipv4 = host { return }
    Issue.record("expected .ipv4 case, got \(host)")
  }

  @Test("DNS name parses as .name")
  func dnsNameParses() {
    let host = AVPHTTPProxy.parseHost("my-mac.local")
    if case .name(let name, _) = host {
      #expect(name == "my-mac.local")
      return
    }
    Issue.record("expected .name case, got \(host)")
  }
}

@MainActor
@Suite("AVPHTTPProxy URL rewrite")
struct AVPHTTPProxyURLRewriteTests {
  @Test("returns nil before listener is ready")
  func returnsNilBeforeReady() {
    let proxy = AVPHTTPProxy()
    let url = URL(string: "https://example.com/preview/foo")!
    #expect(proxy.rewrittenURL(for: url) == nil)
  }
}

@Suite("KosmosVisionService.pickUpstreamHost")
struct KosmosVisionServiceHostPickerTests {
  /// Policy is uniform across simulator and real AVP now: prefer
  /// non-AWDL candidates because Hummingbird's listener doesn't
  /// enable `NWParameters.includePeerToPeer`, so the Mac kernel
  /// refuses AWDL ingress on real AVP just as the simulator has
  /// no AWDL interface at all.
  @Test("AWDL-zoned preferred falls through to candidates")
  func skipsAWDLPreferred() {
    let host = KosmosVisionService.pickUpstreamHost(
      preferred: "fe80::1%awdl0",
      candidates: ["mercury.local", "fe80::1%awdl0", "192.168.1.20"])
    #expect(host == "mercury.local")
  }

  @Test("AWDL-only candidates: returns AWDL as last resort")
  func awdlOnlyLastResort() {
    let host = KosmosVisionService.pickUpstreamHost(
      preferred: "fe80::1%awdl0",
      candidates: ["fe80::1%awdl0", "fe80::2%awdl1"])
    // Every candidate is AWDL — the proxy will attempt and likely
    // fail, but we don't silently drop the open.
    #expect(host == "fe80::1%awdl0")
  }

  @Test("Non-AWDL preferred is kept verbatim")
  func keepsNonAWDLPreferred() {
    let host = KosmosVisionService.pickUpstreamHost(
      preferred: "mercury.local",
      candidates: ["fe80::1%awdl0"])
    #expect(host == "mercury.local")
  }

  @Test("Nil preferred falls back to the first non-AWDL candidate")
  func nilPreferred() {
    let host = KosmosVisionService.pickUpstreamHost(
      preferred: nil,
      candidates: ["fe80::1%awdl0", "192.168.1.20"])
    #expect(host == "192.168.1.20")
  }

  @Test("Mac's real reachableHosts list picks Bonjour first")
  func realWorldOrdering() {
    // Replays the actual `hostCandidates` shape we see in production
    // (Bonjour + global IPv6 + ULA + AWDL + utun tunnels + LAN IPv4).
    let candidates = [
      "mercury.local",
      "2607:fb91:20c6:45e5:1c38:4bfb:8b5c:dde3",
      "2607:fb91:20c6:45e5:5555:41e1:3e8e:cc1f",
      "fd31:d953:181e::2",
      "fd9d:e59:67d::2",
      "fe80::ec1e:81ff:fe21:cff9%awdl0",
      "fe80::fc2b:b996:8aae:8818%utun0",
      "192.0.0.2"
    ]
    let host = KosmosVisionService.pickUpstreamHost(
      preferred: "fe80::ec1e:81ff:fe21:cff9%awdl0",
      candidates: candidates)
    #expect(host == "mercury.local")
  }
}
#endif
