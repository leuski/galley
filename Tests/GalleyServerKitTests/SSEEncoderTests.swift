import Foundation
import Testing
@testable import GalleyServerKit

@Suite("SSEEncoder")
struct SSEEncoderTests {
  @Test("Single-line data emits one data: line and a blank terminator")
  func singleLine() {
    let frame = String(decoding: SSE.encode(data: "ok"), as: UTF8.self)
    #expect(frame == "data: ok\n\n")
  }

  @Test("event field precedes data when supplied")
  func eventField() {
    let frame = String(
      decoding: SSE.encode(event: "reload", data: "ok"),
      as: UTF8.self)
    #expect(frame == "event: reload\ndata: ok\n\n")
  }

  @Test("Multi-line payload splits across data: lines")
  func multiline() {
    let frame = String(
      decoding: SSE.encode(data: "line1\nline2\nline3"),
      as: UTF8.self)
    #expect(frame == "data: line1\ndata: line2\ndata: line3\n\n")
  }

  @Test("Empty payload yields a single empty data: line")
  func emptyData() {
    let frame = String(decoding: SSE.encode(data: ""), as: UTF8.self)
    #expect(frame == "data: \n\n")
  }

  @Test("Trailing newline preserves the empty terminating data: line")
  func trailingNewline() {
    let frame = String(decoding: SSE.encode(data: "x\n"), as: UTF8.self)
    #expect(frame == "data: x\ndata: \n\n")
  }

  @Test("Keep-alive comment frame is well-formed")
  func keepAlive() {
    let frame = String(decoding: SSE.keepAlive, as: UTF8.self)
    #expect(frame == ": keepalive\n\n")
  }
}
