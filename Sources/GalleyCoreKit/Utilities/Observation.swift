//
//  Observation.swift
//  MarkdownPreviewer
//
//  Created by Anton Leuski on 5/2/26.
//

@MainActor
public func observationChanges(
  _ track: @escaping @MainActor () -> Void
) -> AsyncStream<Void> {
  AsyncStream { cont in
    let task = Task { @MainActor in
      while !Task.isCancelled {
        await withCheckedContinuation
        { (checked: CheckedContinuation<Void, Never>) in
          withObservationTracking(track) { checked.resume() }
        }
        cont.yield(())
      }
      cont.finish()
    }
    cont.onTermination = { _ in task.cancel() }
  }
}

@MainActor
@discardableResult
public func onObservedChange(
  track: @escaping @MainActor () -> Void,
  onChange: @escaping @MainActor () -> Void
) -> Cancelable {
  let task = Task { @MainActor in
    while !Task.isCancelled {
      await withCheckedContinuation
      { (cont: CheckedContinuation<Void, Never>) in
        withObservationTracking(track) { cont.resume() }
      }
      if Task.isCancelled { break }
      onChange()
    }
  }
  return ObservationToken(task)
}

// MARK: - Observation

public protocol Cancelable: Sendable {
  func cancel()
}

final private class ObservationToken: Cancelable {
  private let task: Task<Void, Never>

  init(_ task: Task<Void, Never>) {
    self.task = task
  }

  func cancel() {
    task.cancel()
  }

  deinit {
    cancel()
  }
}

public struct GalleyObservation<Value> {
  public let value: Value
  public let token: Cancelable
}
