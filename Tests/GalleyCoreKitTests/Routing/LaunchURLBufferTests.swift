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
    let urlA = URL(fileURLWithPath: "/tmp/a.md")
    let urlB = URL(fileURLWithPath: "/tmp/b.md")
    let urlC = URL(fileURLWithPath: "/tmp/c.md")
    buffer.append(urlA)
    buffer.append(urlB)
    buffer.append(urlC)
    #expect(buffer.count == 3)
    #expect(buffer.pending == [urlA, urlB, urlC])
  }

  @Test("Drain returns FIFO snapshot and clears")
  func drainReturnsAndClears() {
    var buffer = LaunchURLBuffer()
    let urlA = URL(fileURLWithPath: "/tmp/a.md")
    let urlB = URL(fileURLWithPath: "/tmp/b.md")
    buffer.append(urlA)
    buffer.append(urlB)

    let drained = buffer.drain()
    #expect(drained == [urlA, urlB])
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
    let urlA = URL(fileURLWithPath: "/tmp/a.md")
    let urlB = URL(fileURLWithPath: "/tmp/b.md")
    buffer.append(urlA)
    _ = buffer.drain()
    buffer.append(urlB)
    #expect(buffer.pending == [urlB])
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

  /// Calling `drain` twice should leave the buffer empty and return
  /// nothing the second time — the dispatcher's `install(_:)` calls
  /// `drain` unconditionally, so a non-idempotent drain would replay
  /// stale URLs on every install (stale URLs that may already have
  /// gone through the openHandler).
  @Test("Drain is idempotent — second call returns empty array")
  func drainIdempotent() {
    var buffer = LaunchURLBuffer()
    buffer.append(URL(fileURLWithPath: "/tmp/a.md"))
    _ = buffer.drain()
    #expect(buffer.drain() == [])
    #expect(buffer.isEmpty)
  }

  /// FIFO is the contract — `application(_:open:)` may fire several
  /// times for the same launch (Finder dispatching a multi-selection,
  /// LaunchServices replaying a deep link), and `install(_:)` must
  /// hand them to the openHandler in arrival order. Pin against an
  /// accidental switch to a stack or set-based buffer.
  @Test("FIFO order across many appends and a single drain")
  func fifoOrder() {
    var buffer = LaunchURLBuffer()
    let urls = (0..<10).map {
      URL(fileURLWithPath: "/tmp/file-\($0).md")
    }
    for url in urls { buffer.append(url) }
    #expect(buffer.drain() == urls)
  }

  @Test("Equatable: same URLs in same order")
  func equatable() {
    var first = LaunchURLBuffer()
    var second = LaunchURLBuffer()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    first.append(url)
    second.append(url)
    #expect(first == second)
    second.append(URL(fileURLWithPath: "/tmp/b.md"))
    #expect(first != second)
  }

  /// Identical URLs are de-duplicated by the production caller's
  /// upstream dispatchers (NSDocumentController doesn't replay; the
  /// Finder dispatcher is one-shot). The buffer itself is dumb
  /// storage — it MUST preserve duplicates so the caller sees what
  /// actually arrived. Pin against a "smart" set-based optimization.
  @Test("Duplicate URLs are preserved in arrival order")
  func duplicatesPreserved() {
    var buffer = LaunchURLBuffer()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    buffer.append(url)
    buffer.append(url)
    #expect(buffer.count == 2)
    #expect(buffer.drain() == [url, url])
  }
}
