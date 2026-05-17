import Foundation
import GalleyCoreKit

/// Drives the Settings-pane status pill. Iterates a `ServerProbe`
/// async sequence while a caller-owned `Task` is alive (typically
/// scoped via `.task(id:)`), updates `status` on the main actor,
/// and stops as soon as the task is cancelled.
///
/// Owns the startup-grace lifecycle: each call to `run(host:)`
/// resets `graceRemaining` to `startupGraceCount`, so every fresh
/// invocation (i.e. every toggle-on event from `.task(id:)`) gets
/// its own grace budget. The grace itself is applied via the pure
/// `applyStartupGrace(_:graceRemaining:)` helper from
/// `GalleyCoreKit`.
@MainActor @Observable
final class ServerStatusModel {
  private(set) var status: ServerStatus = .unknown

  @ObservationIgnored private let timeout: TimeInterval
  @ObservationIgnored private let pollInterval: Duration
  @ObservationIgnored private let startupGraceCount: Int

  init(
    timeout: TimeInterval = 1.0,
    pollInterval: Duration = .seconds(2),
    startupGraceCount: Int = 2)
  {
    self.timeout = timeout
    self.pollInterval = pollInterval
    self.startupGraceCount = startupGraceCount
  }

  /// When `enabled` is false, sets `.disabled` and returns. Otherwise
  /// loops over a fresh `ServerProbe` sequence until the surrounding
  /// task is cancelled. The probe re-resolves its host on every
  /// iteration via `hostProvider`, so a server restart that publishes
  /// a new port through `ServerPortFile` is picked up automatically.
  ///
  /// Resets to `.unknown` and refreshes the grace budget first so the
  /// pill clears any stale value from a previous run and the first
  /// two `.stopped`/`.notResponding` results read as `.starting`.
  func run(
    enabled: Bool,
    hostProvider: @escaping @Sendable () -> URL?
  ) async {
    guard enabled else {
      status = .disabled
      return
    }
    status = .unknown
    var graceRemaining = startupGraceCount
    let probe = ServerProbe(
      hostProvider: hostProvider,
      timeout: timeout,
      pollInterval: pollInterval)
    for await raw in probe {
      if Task.isCancelled { return }
      status = applyStartupGrace(raw, graceRemaining: &graceRemaining)
    }
  }
}
