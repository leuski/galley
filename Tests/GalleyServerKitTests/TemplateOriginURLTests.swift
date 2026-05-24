//
//  TemplateOriginURLTests.swift
//
//  Pin the origin-selection policy `Routes.templateOriginURL` uses to
//  build `<base href>` for rendered HTML. The honored override is
//  `X-Galley-Origin`, set exclusively by the AVP-side loopback proxy
//  (`AVPHTTPProxy`) so sub-resource fetches stay on the proxy's
//  loopback origin instead of escaping to the upstream LAN authority.
//
//  Note: existing cases cover the pure decision via the
//  `originHeader:` overload, so the `HTTPField.Name` constant
//  lift in `Routes.swift` is behavior-preserving.
//

#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

@Suite("templateOriginURL")
struct TemplateOriginURLTests {
  private let fallback = URL(string: "https://listener.local:9999/")!

  @Test("falls back to hostURL when neither header nor authority present")
  func fallbackOnly() {
    let url = Routes.templateOriginURL(
      originHeader: nil, authority: nil, fallback: fallback)
    #expect(url == fallback)
  }

  @Test("uses authority when no X-Galley-Origin")
  func authorityFromHost() {
    let url = Routes.templateOriginURL(
      originHeader: nil,
      authority: "mercury.local:54201",
      fallback: fallback)
    #expect(url.absoluteString == "https://mercury.local:54201")
  }

  @Test("X-Galley-Origin overrides Host authority")
  func headerOverridesHost() {
    let url = Routes.templateOriginURL(
      originHeader: "http://127.0.0.1:54290/",
      authority: "mercury.local:54201",
      fallback: fallback)
    #expect(url.absoluteString == "http://127.0.0.1:54290/")
  }

  @Test("X-Galley-Origin used even with empty Host")
  func headerWithoutHost() {
    let url = Routes.templateOriginURL(
      originHeader: "http://127.0.0.1:54290/",
      authority: nil,
      fallback: fallback)
    #expect(url.absoluteString == "http://127.0.0.1:54290/")
  }

  @Test("blank X-Galley-Origin is ignored")
  func blankHeaderIgnored() {
    let url = Routes.templateOriginURL(
      originHeader: "   ",
      authority: "mercury.local:54201",
      fallback: fallback)
    #expect(url.absoluteString == "https://mercury.local:54201")
  }

  @Test("malformed X-Galley-Origin falls through to authority")
  func malformedHeader() {
    let url = Routes.templateOriginURL(
      originHeader: "not a url",
      authority: "mercury.local:54201",
      fallback: fallback)
    #expect(url.absoluteString == "https://mercury.local:54201")
  }

  @Test("scheme-less header falls through to authority")
  func schemelessHeader() {
    // `URL(string:)` accepts `127.0.0.1:54290` as a path; we require
    // a real scheme so a misconfigured override doesn't produce a
    // garbage base href.
    let url = Routes.templateOriginURL(
      originHeader: "127.0.0.1:54290",
      authority: "mercury.local:54201",
      fallback: fallback)
    #expect(url.absoluteString == "https://mercury.local:54201")
  }
}
#endif
