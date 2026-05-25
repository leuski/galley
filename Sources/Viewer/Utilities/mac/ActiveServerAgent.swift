#if os(macOS)
import AppKit
import Foundation
import Observation

/// SwiftUI-visible facade over the launchd-backed server agent.
/// Exposes `isEnabled` as an observable property so views can
/// `@Bindable` against it or just read it in `body` and get
/// automatic re-evaluation; async mutations update `isEnabled`
/// before returning.
///
/// The live backend is ``LaunchctlServerAgent`` (classic per-user
/// `~/Library/LaunchAgents/`). It is the only backend currently
/// wired in. If a future alternative is added, swap `backend` for
/// another type that implements the same surface (`isEnabled`,
/// `setEnabled`, `validateAndRepair`, `kickstart`) and leave
/// `ServerSettingsView` / `MacViewerApp` untouched.
///
/// ## Why not `SMAppService`?
///
/// Earlier versions used `SMAppService` (Apple's blessed Login-Item
/// API — surfaces in System Settings → Login Items, stable identity
/// across rebuilds via the host's Team ID). On ad-hoc and
/// Apple-Development-signed builds, AMFI rejects the embedded
/// `Galley Server.app` with `OS_REASON_CODESIGNING / Launch
/// Constraint Violation` when launchd spawns it through the
/// SMAppService constraint-enforced path. Combined with
/// `KeepAlive`, the rejected helper respawned in a tight loop and
/// churned ControlCenter's status-item registration. Classic
/// per-user LaunchAgents bypass that constraint check when the
/// binary carries no LWCR of its own, which is the path
/// ``LaunchctlServerAgent`` takes.
///
/// ## Going forward
///
/// One cleaner option is launching `Galley Server.app` as a child
/// of `Galley.app` via `NSWorkspace.openApplication(...)` — no
/// plist on disk, no path drift, no AMFI launch-constraint check.
/// The blocker: Server is the AVP routing authority (LSHandler for
/// `.md` and `galley-bridge://`) and must outlive `Galley.app`, so
/// a child-process model is the wrong shape.
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
#endif
