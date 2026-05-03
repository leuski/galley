import Foundation
import GalleyCoreKit

/// Drives the Settings-pane status pill. Polls `ServerProbe` while a
/// caller-owned `Task` is alive (typically scoped via `.task(id:)`),
/// updates `status` on the main actor, and stops as soon as the task
/// is cancelled.
@MainActor @Observable
final class ServerStatusModel {
  private(set) var status: ServerStatus = .unknown

  @ObservationIgnored private let probe: ServerProbe
  @ObservationIgnored private let pollInterval: Duration

  init(
    probe: ServerProbe = ServerProbe(timeout: 1.0),
    pollInterval: Duration = .seconds(2))
  {
    self.probe = probe
    self.pollInterval = pollInterval
  }

  /// When `host` is nil, sets `.disabled` and returns. Otherwise loops
  /// until the surrounding task is cancelled, probing on every tick.
  /// The first probe runs immediately so the pill updates within
  /// `timeout`, not `pollInterval`.
  func run(host: URL?) async {
    guard let host else {
      status = .disabled
      return
    }
    while !Task.isCancelled {
      let next = await probe.probe(host: host)
      if Task.isCancelled { return }
      status = next
      try? await Task.sleep(for: pollInterval)
    }
  }
}
