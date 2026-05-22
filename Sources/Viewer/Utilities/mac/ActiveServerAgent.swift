import AppKit
import Foundation
import Observation

/// Single swap point for the server-agent backend. Exposes
/// `isEnabled` as an observable property so SwiftUI views can
/// `@Bindable` against it or just read it in `body` and get
/// automatic re-evaluation; async mutations update `isEnabled`
/// before returning.
///
/// To switch backends, swap `backend` for another type that
/// implements the same surface (`isEnabled`, `setEnabled`,
/// `validateAndRepair`). Don't change `ServerSettingsView` or
/// `ViewerApp`.
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
@MainActor
@Observable
final class ActiveServerAgent {
  static let shared = ActiveServerAgent()

  /// Observed by SwiftUI. Mirrors the backend's persisted state;
  /// kept in sync by `refresh()` at construction and after every
  /// mutating call.
  private(set) var isEnabled: Bool = false

  @ObservationIgnored
  private let backend = LaunchctlServerAgent()

  private init() {
    // Hydrate from launchd on first access. Fire-and-forget — the
    // initial `false` is the right default when nothing is
    // installed, and views re-evaluate as soon as the async load
    // returns.
    Task { await refresh() }
  }

  func refresh() async {
    isEnabled = await backend?.isEnabled ?? false
  }

  /// Toggle Login-Item registration. When `enabled == false`, also
  /// terminates any currently running Server process: the toggle is
  /// the user's "Server on / off" switch, not a Login-Item-only
  /// affordance. Without the explicit terminate, a Server launched
  /// outside launchd (e.g. via `NSWorkspace.openApplication` from
  /// the relaunch path, or a manual Finder launch) survives the
  /// toggle-off and the menu-bar icon stays visible, which reads as
  /// a broken switch.
  @discardableResult
  func setEnabled(_ enabled: Bool) async -> Bool {
    let actual = await backend?.setEnabled(enabled) ?? false
    if !enabled {
      terminateRunningServers()
    }
    isEnabled = actual
    return actual
  }

  /// Call once per launch. No-op for backends that don't need
  /// launch-time path validation.
  func validateAndRepair() async {
    await backend?.validateAndRepair()
    await refresh()
  }

  /// Forwarded to the backend. Returns `true` when the service was
  /// kickstarted; `false` when the backend isn't bootstrapped and
  /// the caller should fall back to `NSWorkspace.openApplication`.
  @discardableResult
  func kickstart() async -> Bool {
    await backend?.kickstart() ?? false
  }

  /// Politely terminate every `net.leuski.galley.server` process
  /// owned by this user. `terminate()` sends `NSWorkspace`'s
  /// quit-application Apple event, which the menu-bar `MenuBarExtra`
  /// honors cleanly.
  private func terminateRunningServers() {
    guard let bundleID = backend?.label else { return }
    let running = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleID)
    for app in running {
      app.terminate()
    }
  }
}
