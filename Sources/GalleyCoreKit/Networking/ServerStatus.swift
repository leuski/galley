import Foundation

/// Reachability of the Markdown Preview Server, as observed from a
/// client (the Viewer's settings pane). Distinct from
/// `PreviewServerController.State`, which is the server's own
/// in-process view.
public enum ServerStatus: Equatable, Sendable {
  /// No probe has completed yet.
  case unknown

  /// The user has the toggle off; we are not probing.
  case disabled

  /// The probe just started and the server has not yet answered;
  /// `.stopped`/`.notResponding` during this initial grace window are
  /// reported as `.starting` so the UI doesn't flash a red "Not
  /// running" state during normal launch.
  case starting

  /// `GET /` returned a 2xx response. The associated URL is the host
  /// that responded, suitable for "Running on :8089"-style display.
  case running(URL)

  /// Connection refused — nothing is bound on this port. This is the
  /// expected state when the Server agent failed to launch.
  case stopped

  /// Anything else: timeout, non-2xx response, transport error.
  /// Distinct from `.stopped` so callers can surface a different hint
  /// ("did the server hang?" vs "did it never start?").
  case notResponding
}
