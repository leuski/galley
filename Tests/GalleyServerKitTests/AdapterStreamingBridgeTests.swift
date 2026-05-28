#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

/// The streaming bridge turns the push-based `ResponseBody { writer in ... }`
/// closure (Hummingbird shape) into an `AsyncBufferedSequence<UInt8>` that
/// FlyingFox can consume via `HTTPBodySequence(from:)`. SSE is the only
/// caller today — `/events/<path>` writes each `event: reload` payload
/// chunk-by-chunk and `writer.finish(nil)` once the watcher's subscription
/// drops. The bridge must:
///   - yield every byte the producer writes, in order,
///   - terminate iteration when the producer returns (or throws),
///   - report nil from `next()` after termination so FlyingFox closes the
///     chunked response cleanly.
@Suite("Adapter/Streaming bridge")
struct AdapterStreamingBridgeTests {
  @Test("Yields every byte the producer writes, in order")
  func yieldsAllBytes() async throws {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    continuation.yield(Data([0x48, 0x49]))        // "HI"
    continuation.yield(Data([0x0A]))              // "\n"
    continuation.finish()

    let sequence = PushBufferedSequence(stream: stream)
    var iterator = sequence.makeAsyncIterator()

    var bytes: [UInt8] = []
    while let next = try await iterator.next() {
      bytes.append(next)
    }
    #expect(bytes == [0x48, 0x49, 0x0A])
  }

  @Test("nextBuffer returns the producer chunks one at a time")
  func nextBufferReturnsOneChunkAtATime() async throws {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    continuation.yield(Data("abc".utf8))
    continuation.yield(Data("de".utf8))
    continuation.finish()

    let sequence = PushBufferedSequence(stream: stream)
    var iterator = sequence.makeAsyncIterator()

    // Each yield is surfaced as its own buffer so chunked-transfer
    // emits one HTTP chunk per producer write — important for SSE's
    // line-level flush latency.
    let first = try await iterator.nextBuffer(suggested: 4096)
    #expect(first.map(Array.init) == [0x61, 0x62, 0x63])

    let second = try await iterator.nextBuffer(suggested: 4096)
    #expect(second.map(Array.init) == [0x64, 0x65])

    let third = try await iterator.nextBuffer(suggested: 4096)
    #expect(third == nil)
  }

  @Test("Empty producer terminates immediately")
  func emptyProducerTerminates() async throws {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    continuation.finish()

    let sequence = PushBufferedSequence(stream: stream)
    var iterator = sequence.makeAsyncIterator()

    #expect(try await iterator.next() == nil)
  }
}
#endif
