import Foundation

/// FIFO buffer for URLs that arrive via `application(_:open:)` before
/// SwiftUI has installed the `openWindow` handler. The Viewer's
/// AppKit adapter pushes each inbound URL through `append(_:)` while
/// the handler is `nil`; once the first window comes up and registers
/// its handler, the adapter calls `drain()` and replays every queued
/// URL through the now-installed handler.
///
/// Pure value type — owns no behavior beyond push/drain. Lets the
/// chicken-and-egg "no window yet, but a URL just arrived" path stay
/// deterministic and testable without spinning up SwiftUI.
public struct LaunchURLBuffer: Sendable, Equatable {
  private var queue: [URL] = []

  public init() {}

  public var isEmpty: Bool { queue.isEmpty }
  public var count: Int { queue.count }

  /// Snapshot the queue without draining it — useful for assertions
  /// and for serializing pending state during diagnostic logging.
  public var pending: [URL] { queue }

  public mutating func append(_ url: URL) {
    queue.append(url)
  }

  /// Atomically clear the buffer and return everything that was
  /// queued. Caller is responsible for replaying through the
  /// now-installed handler.
  public mutating func drain() -> [URL] {
    let snapshot = queue
    queue.removeAll(keepingCapacity: false)
    return snapshot
  }
}
