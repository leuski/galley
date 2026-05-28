import Foundation
import FlyingSocks

// Bridge from the Hummingbird-shaped streaming producer
// (`ResponseBody { writer in ... }`) to FlyingFox's pull-based
// `AsyncBufferedSequence<UInt8>` contract, which `HTTPBodySequence(from:)`
// wraps in `HTTPChunkedTransferEncoder` for the wire.
//
// Each `Data` chunk fed in via the `AsyncStream` becomes one HTTP chunk
// downstream — that's what makes the bridge correct for SSE: every
// `writer.write(buffer)` flushes a separate chunk so live-reload events
// arrive line-by-line on the client.
//
// Iteration completes when the producer side calls `continuation.finish()`
// (whether the closure returned normally, threw, or was cancelled). After
// that point `next()` / `nextBuffer(suggested:)` return nil and FlyingFox
// emits a zero-length terminator chunk to close the response cleanly.

struct PushBufferedSequence: AsyncBufferedSequence {
  typealias Element = UInt8

  let stream: AsyncStream<Data>

  func makeAsyncIterator() -> Iterator {
    Iterator(base: stream.makeAsyncIterator())
  }

  struct Iterator: AsyncBufferedIteratorProtocol {
    typealias Element = UInt8
    typealias Buffer = ArraySlice<UInt8>

    private var base: AsyncStream<Data>.Iterator
    /// Bytes pulled from the upstream chunk but not yet handed out by
    /// `next()`. Kept so the byte-at-a-time iterator interface still
    /// works (FlyingFox uses `nextBuffer(suggested:)` for chunked
    /// transfer, but the protocol must also support `next()`).
    private var pending: ArraySlice<UInt8> = []

    init(base: AsyncStream<Data>.Iterator) {
      self.base = base
    }

    mutating func next() async -> UInt8? {
      while pending.isEmpty {
        guard let chunk = await base.next() else { return nil }
        if chunk.isEmpty { continue }
        pending = ArraySlice(chunk)
      }
      return pending.removeFirst()
    }

    mutating func nextBuffer(
      suggested count: Int
    ) async throws -> ArraySlice<UInt8>? {
      // Prefer the pending overflow first so a caller that interleaves
      // `next()` with `nextBuffer(suggested:)` sees bytes in order.
      if !pending.isEmpty {
        let out = pending
        pending = []
        return out
      }
      while let chunk = await base.next() {
        if chunk.isEmpty { continue }
        return ArraySlice(chunk)
      }
      return nil
    }
  }
}
