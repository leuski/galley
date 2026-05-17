import Foundation

/// Single swap point for the server-agent backend. Exposes an async
/// API even when the underlying impl is synchronous, so callers don't
/// have to know which one is in use.
///
/// To switch backends, change the bodies of these two members. Don't
/// change `ServerSettingsView` or `ViewerApp`.
///
/// ## Backends
///
/// ``ServerAgent`` (`SMAppService`)
///   The Apple-blessed path. Surfaces in System Settings → Login
///   Items, has a stable identity across rebuilds (via the host
///   bundle's Team ID). On Apple-Development-signed local builds,
///   AMFI rejects the embedded `Galley Server.app` with `Launch
///   Constraint Violation`; combined with `KeepAlive` this can
///   respawn-loop and destabilize the user session.
///
/// ``LaunchctlServerAgent`` (classic `~/Library/LaunchAgents`)
///   Bypasses SMAppService. Sidesteps the SMAppService AMFI path,
///   but the LWCR baked into the embedded helper still applies if
///   present. The plist also embeds an absolute `Program` path,
///   which goes stale if `Galley.app` moves —
///   ``LaunchctlServerAgent/validateAndRepair()`` repairs that on
///   launch. Plist no longer uses `KeepAlive`, so a failed spawn
///   stays failed instead of looping.
///
/// ## Going forward
///
/// The reliable option is to launch `Galley Server.app` as a child
/// of `Galley.app` via `NSWorkspace.openApplication(...)` while
/// Galley is running. LaunchServices handles parent-identity
/// correctly, AMFI is happy, no plist on disk, no path drift.
/// Trade-off: the server lives only as long as Galley does.
enum ActiveServerAgent {
  static var isEnabled: Bool {
    get async {
      await LaunchctlServerAgent.isEnabled
    }
  }

  @discardableResult
  static func setEnabled(_ enabled: Bool) async -> Bool {
    await LaunchctlServerAgent.setEnabled(enabled)
  }

  /// Forwarded for `ViewerApp.init`. No-op for backends that don't
  /// need launch-time path validation.
  static func validateAndRepair() async {
    await LaunchctlServerAgent.validateAndRepair()
  }
}
