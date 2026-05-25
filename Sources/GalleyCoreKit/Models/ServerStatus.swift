import Foundation

/// State of the Galley Server as reported through Kosmos, used by the
/// Settings-pane status pill. The transitions are driven by two
/// independent signals — Kosmos peer presence (truth of "is running")
/// and `ActiveServerAgent.isEnabled` (truth of "user wants it on") —
/// plus a 5-second grace window after the user expresses intent so we
/// don't flash a red "not responding" state during normal launch.
public enum ServerStatus: Equatable, Sendable {
  /// No Kosmos signal and the user has not enabled the Server. The
  /// expected steady state when the user has never turned Galley's
  /// Server on.
  case disabled

  /// User intent is on (LaunchAgent registered, or the user just
  /// flipped the toggle) but Kosmos hasn't reported the Server peer
  /// yet. Limited to the 5-second grace window after intent went on;
  /// after that, transitions to `.notResponding`.
  case starting

  /// Server peer is connected via Kosmos. The associated URL is the
  /// Server's loopback HTTP base URL, published in its peer metadata —
  /// the pill shows the port from it.
  case running(URL)

  /// User intent is on, the grace window has elapsed, and Kosmos
  /// still doesn't see the Server peer. Something is wrong — the
  /// LaunchAgent failed to spawn, the process crashed, Local Network
  /// permission is denied, etc.
  case notResponding
}
