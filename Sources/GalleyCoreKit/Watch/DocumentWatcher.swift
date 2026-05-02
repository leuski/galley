import Foundation
import ALFoundation

public actor DocumentWatcher {
  private struct Entry {
    let url: URL
    var subscribers: [UUID: AsyncStream<Void>.Continuation]
    let task: Task<Void, Never>
  }

  private var entries: [String: Entry] = [:]

  public init() {}

  public func subscribe(to url: URL) -> AsyncStream<Void> {
    let key = url.safe.path
    let id = UUID()

    let stream = AsyncStream<Void> { [weak self] continuation in
      guard let self else { continuation.finish(); return }
      Task {
        await self.attach(
          id: id, url: url, key: key, continuation: continuation)
      }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.detach(id: id, key: key) }
      }
    }
    return stream
  }

  private func attach(
    id: UUID,
    url: URL,
    key: String,
    continuation: AsyncStream<Void>.Continuation
  ) {
    if var entry = entries[key] {
      entry.subscribers[id] = continuation
      entries[key] = entry
      return
    }

    let task = Task { [weak self] in
      guard let self else { return }
      await self.consume(url: url, key: key)
    }

    entries[key] = Entry(
      url: url,
      subscribers: [id: continuation],
      task: task)
  }

  private func consume(url: URL, key: String) async {
    // `contentChanges` watches the parent directory via FSEvents and
    // filters for `url`, which survives editor atomic saves
    // (write-temp + rename) — the previous `fileEvents` watcher held
    // an fd to the original inode and went silent after one rename.
    let events = url.contentChanges(
      latency: 0.05,
      queue: .global(qos: .userInitiated))

    var debounce: Task<Void, Never>?
    for await _ in events {
      debounce?.cancel()
      debounce = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        await self?.broadcast(key: key)
      }
    }
  }

  private func detach(id: UUID, key: String) {
    guard var entry = entries[key] else { return }
    entry.subscribers.removeValue(forKey: id)
    if entry.subscribers.isEmpty {
      entry.task.cancel()
      entries.removeValue(forKey: key)
    } else {
      entries[key] = entry
    }
  }

  private func broadcast(key: String) {
    guard let entry = entries[key] else { return }
    for continuation in entry.subscribers.values {
      continuation.yield(())
    }
  }
}
