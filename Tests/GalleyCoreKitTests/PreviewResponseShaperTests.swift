import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("PreviewResponseShaper")
struct PreviewResponseShaperTests {
  private let shaper = PreviewResponseShaper()

  @Test("rendered HTML injects the live-reload script and nonce CSP")
  func htmlShaping() {
    let url = URL(fileURLWithPath: "/tmp/doc.md")
    let shaped = shaper.shape(.html("<html><body><p>Hi</p></body></html>",
                                    documentURL: url))
    #expect(shaped.status == 200)
    guard case .bytes(let data) = shaped.body else {
      Issue.record("expected bytes body"); return
    }
    let html = String(decoding: data, as: UTF8.self)
    // Reload script injected before </body>.
    #expect(html.contains("EventSource('/events/tmp/doc.md')"))
    #expect(html.range(of: "</script>")!.upperBound
      <= html.range(of: "</body>")!.lowerBound)
    #expect(shaped.headers["Content-Type"] == "text/html; charset=utf-8")
    #expect(shaped.headers["Cache-Control"] == "no-store")
    // CSP carries the same nonce the script tag uses.
    let csp = shaped.headers["Content-Security-Policy"] ?? ""
    let nonce = String(
      html.firstMatch(of: /nonce="([^"]+)"/)?.1 ?? "")
    #expect(!nonce.isEmpty)
    #expect(csp.contains("'nonce-\(nonce)'"))
  }

  @Test("a static asset carries no-store + nosniff and its MIME")
  func assetShaping() {
    let bytes = Data([1, 2, 3, 4])
    let shaped = shaper.shape(.bytes(ResolvedBytes(
      data: bytes, mime: "text/css", cache: .noStore)))
    #expect(shaped.status == 200)
    guard case .bytes(let data) = shaped.body else {
      Issue.record("expected bytes body"); return
    }
    #expect(data == bytes)
    #expect(shaped.headers["Content-Type"] == "text/css")
    #expect(shaped.headers["X-Content-Type-Options"] == "nosniff")
  }

  @Test("an event stream has SSE headers and an eventStream body")
  func eventStreamShaping() {
    let url = URL(fileURLWithPath: "/tmp/doc.md")
    let shaped = shaper.shape(.events(documentURL: url))
    #expect(shaped.status == 200)
    #expect(shaped.headers["Content-Type"] == "text/event-stream")
    #expect(shaped.headers["Cache-Control"] == "no-cache")
    guard case .eventStream(let documentURL) = shaped.body else {
      Issue.record("expected eventStream body"); return
    }
    #expect(documentURL == url)
  }

  @Test("a render failure becomes a 500 localized error page")
  func errorPageShaping() {
    let shaped = shaper.shape(.failure(.render(
      detail: "boom", source: "# src")))
    #expect(shaped.status == 500)
    #expect(shaped.headers["Content-Type"] == "text/html; charset=utf-8")
    guard case .bytes(let data) = shaped.body else {
      Issue.record("expected bytes body"); return
    }
    let html = String(decoding: data, as: UTF8.self)
    #expect(html.contains("boom"))
    #expect(html.contains("# src"))
  }

  @Test("notFound becomes a 404 plain-text body")
  func notFoundShaping() {
    let shaped = shaper.shape(.notFound("nope"))
    #expect(shaped.status == 404)
    #expect(shaped.headers["Content-Type"] == "text/plain; charset=utf-8")
    guard case .bytes(let data) = shaped.body else {
      Issue.record("expected bytes body"); return
    }
    #expect(String(decoding: data, as: UTF8.self) == "nope\n")
  }

  @Test("SSE frames match the live-reload protocol")
  func sseFrames() {
    guard case .body(let prelude) = TunnelResponseEvent.connectPrelude,
          case .body(let reload) = TunnelResponseEvent.reloadFrame else {
      Issue.record("expected .body events"); return
    }
    #expect(String(decoding: prelude, as: UTF8.self) == ": connected\n\n")
    #expect(String(decoding: reload, as: UTF8.self)
      == "event: reload\ndata: ok\n\n")
  }
}
