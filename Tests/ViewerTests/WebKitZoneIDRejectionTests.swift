//
//  WebKitZoneIDRejectionTests.swift
//  Galley — visionOS slice
//
//  Pins the WebKit behavior that gates the AVP routing path: visionOS
//  WebKit rejects URLs whose host carries an IPv6 zone-id
//  (`fe80::…%awdl0`) with `WebKitErrorDomain Code=101 — "The URL can't
//  be shown"` (a.k.a. `WebKitErrorCannotShowURL`) *before* any network
//  attempt. Observed live on AVP device, both on-AP and off-AP.
//
//  Foundation parses the URL fine — `URL(string:).host` returns the
//  zoned host literal verbatim — so the rejection happens entirely
//  inside WebKit's URL acceptance layer. That means we can reproduce
//  it in the simulator without needing real AWDL connectivity: the
//  reject fires before WebKit ever tries to open a socket.
//
//  This test drives the **production surface** — SwiftUI's `WebPage`
//  via `for try await _ in page.load(URLRequest(url:))` — not the
//  underlying `WKWebView`. The two share the same URL acceptance
//  layer in current visionOS, but pinning the production wrapper
//  protects against future API drift where `WebPage` could add its
//  own URL filtering on top of WebKit's.
//
//  Why this exists in the test suite rather than only as a probe: we
//  want the build to fail loud if a future visionOS release ever
//  starts accepting zone-id URLs — that's the signal to revisit
//  `BridgeURLBuilder.preferredAVPHost` and the entire AVP transport
//  strategy.
//

#if os(visionOS)
import Foundation
import Testing
import WebKit

@MainActor
@Suite("visionOS WebKit URL acceptance")
struct WebKitZoneIDRejectionTests {
  /// The core repro. Hand `WebPage.load(_:)` a bracketed IPv6+zone
  /// URL; expect the navigation sequence to throw with
  /// `WebKitErrorDomain Code=101` (`WebKitErrorCannotShowURL`)
  /// surfacing through `WebPage.NavigationError`.
  ///
  /// Port `1` is intentional — even if WebKit *did* accept the URL,
  /// nothing is listening on this port, so we'd see a different
  /// underlying error (`NSURLErrorCannotConnectToHost` or similar). A
  /// code-101 failure confirms the reject is at the URL-parser layer,
  /// not network.
  @Test("Bracketed IPv6+zone URL → WebKitErrorCannotShowURL (code 101)")
  func zoneIDURLRejected() async throws {
    let url = try #require(
      URL(string: "https://[fe80::1%25awdl0]:1/"),
      "URL string must parse at Foundation level")
    let page = WebPage()

    var caught: (any Error)?
    do {
      for try await _ in page.load(url) { }
    } catch {
      caught = error
    }
    let error = try #require(
      caught,
      "Expected WebPage.load to throw; it completed normally instead.")

    let underlying = Self.underlyingNSError(of: error)
    #expect(
      underlying.domain == "WebKitErrorDomain",
      """
      expected underlying domain WebKitErrorDomain, got \
      \(underlying.domain) — full reflection: \(String(reflecting: error))
      """)
    #expect(
      underlying.code == 101,
      """
      expected underlying code 101 (WebKitErrorCannotShowURL), got \
      \(underlying.code) — \(underlying.localizedDescription)
      """)
  }

  /// Sanity check: an `about:blank` load on the same `WebPage` shape
  /// completes without throwing. Pins that the failure above is the
  /// URL itself, not the test harness (no view-in-window, no UIScene,
  /// etc.).
  @Test("about:blank loads successfully — harness sanity")
  func aboutBlankLoadsSuccessfully() async throws {
    let url = try #require(URL(string: "about:blank"))
    let page = WebPage()
    for try await _ in page.load(URLRequest(url: url)) { }
  }

  /// `WebPage.NavigationError` wraps the underlying WebKit `NSError`
  /// inside an enum case's associated value (e.g.
  /// `.failedProvisionalNavigation(Error)`). Reflection-based
  /// extraction is resilient to case-name changes across SDKs — we
  /// only need the wrapped `NSError` to assert on its domain + code.
  /// Falls back to bridging the top-level error if no nested error
  /// is found.
  private static func underlyingNSError(of error: any Error) -> NSError {
    let mirror = Mirror(reflecting: error)
    for child in mirror.children {
      if let nested = child.value as? any Error {
        return nested as NSError
      }
    }
    return error as NSError
  }
}
#endif
