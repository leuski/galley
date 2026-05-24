#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

@Suite("SSEEncoder")
struct SSEEncoderTests {
  @Test("Single-line data emits one data: line and a blank terminator")
  func singleLine() {
    let frame = String(bytes: SSE.encode(data: "ok"), encoding: .utf8) ?? ""
    #expect(frame == "data: ok\n\n")
  }

  @Test("event field precedes data when supplied")
  func eventField() {
    let frame = String(
      bytes: SSE.encode(event: "reload", data: "ok"),
      encoding: .utf8) ?? ""
    #expect(frame == "event: reload\ndata: ok\n\n")
  }

  @Test("Multi-line payload splits across data: lines")
  func multiline() {
    let frame = String(
      bytes: SSE.encode(data: "line1\nline2\nline3"),
      encoding: .utf8) ?? ""
    #expect(frame == "data: line1\ndata: line2\ndata: line3\n\n")
  }

  @Test("Empty payload yields a single empty data: line")
  func emptyData() {
    let frame = String(bytes: SSE.encode(data: ""), encoding: .utf8) ?? ""
    #expect(frame == "data: \n\n")
  }

  @Test("Trailing newline preserves the empty terminating data: line")
  func trailingNewline() {
    let frame = String(bytes: SSE.encode(data: "x\n"), encoding: .utf8) ?? ""
    #expect(frame == "data: x\ndata: \n\n")
  }

  @Test("Keep-alive comment frame is well-formed")
  func keepAlive() {
    let frame = String(bytes: SSE.keepAlive, encoding: .utf8) ?? ""
    #expect(frame == ": keepalive\n\n")
  }
}
#endif
