import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("LaunchURLBuffer")
struct LaunchURLBufferTests {
  @Test("Starts empty")
  func startsEmpty() {
    let buffer = LaunchURLBuffer()
    #expect(buffer.isEmpty)
    #expect(buffer.count == 0)
    #expect(buffer.pending == [])
  }

  @Test("Appends preserve order")
  func appendsPreserveOrder() {
    var buffer = LaunchURLBuffer()
    let a = URL(fileURLWithPath: "/tmp/a.md")
    let b = URL(fileURLWithPath: "/tmp/b.md")
    let c = URL(fileURLWithPath: "/tmp/c.md")
    buffer.append(a)
    buffer.append(b)
    buffer.append(c)
    #expect(buffer.count == 3)
    #expect(buffer.pending == [a, b, c])
  }

  @Test("Drain returns FIFO snapshot and clears")
  func drainReturnsAndClears() {
    var buffer = LaunchURLBuffer()
    let a = URL(fileURLWithPath: "/tmp/a.md")
    let b = URL(fileURLWithPath: "/tmp/b.md")
    buffer.append(a)
    buffer.append(b)

    let drained = buffer.drain()
    #expect(drained == [a, b])
    #expect(buffer.isEmpty)
    #expect(buffer.pending == [])
  }

  @Test("Drain on empty buffer returns empty array")
  func drainEmpty() {
    var buffer = LaunchURLBuffer()
    #expect(buffer.drain() == [])
    #expect(buffer.isEmpty)
  }

  @Test("Re-append after drain works")
  func reAppendAfterDrain() {
    var buffer = LaunchURLBuffer()
    let a = URL(fileURLWithPath: "/tmp/a.md")
    let b = URL(fileURLWithPath: "/tmp/b.md")
    buffer.append(a)
    _ = buffer.drain()
    buffer.append(b)
    #expect(buffer.pending == [b])
  }

  @Test("Buffer copies are independent (value semantics)")
  func valueSemantics() {
    var original = LaunchURLBuffer()
    original.append(URL(fileURLWithPath: "/tmp/a.md"))
    var copy = original
    copy.append(URL(fileURLWithPath: "/tmp/b.md"))
    #expect(original.count == 1)
    #expect(copy.count == 2)
  }
}
