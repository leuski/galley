//
//  Observation.swift
//  Galley
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
  let (stream, continuation) = AsyncStream<Void>.makeStream()

  // Arm the observation synchronously so a mutation that happens
  // between this call returning and the consumer Task being scheduled
  // is not lost. (`withObservationTracking` is single-shot — once the
  // tracked block fires, observation must be re-armed for the next
  // change.)
  @MainActor func arm() {
    withObservationTracking(track) {
      continuation.yield(())
    }
  }
  arm()

  let task = Task { @MainActor in
    for await _ in stream {
      if Task.isCancelled { break }
      onChange()
      arm()
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
