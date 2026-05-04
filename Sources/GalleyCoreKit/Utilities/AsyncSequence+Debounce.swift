import Foundation

extension AsyncSequence where Self: Sendable, Failure == Never {
  /// Emits one tick after `duration` of upstream quiescence. Each new
  /// upstream element cancels any pending tick and starts a fresh
  /// timer; the downstream sees a tick only once the upstream falls
  /// silent for `duration`.
  ///
  /// Used to coalesce bursts of FSEvents into a single reload. The
  /// element is discarded — callers that only need to know "something
  /// happened, the dust has settled" can subscribe with `for await _`.
  public func debounce(for duration: Duration) -> AsyncStream<Void> {
    AsyncStream { continuation in
      let task = Task {
        var pending: Task<Void, Never>?
        for await _ in self {
          pending?.cancel()
          pending = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            continuation.yield(())
          }
        }
        pending?.cancel()
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
