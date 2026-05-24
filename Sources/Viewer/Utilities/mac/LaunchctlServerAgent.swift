#if os(macOS)
import Foundation
import OSLog
import GalleyCoreKit
import ALFoundation

private let launchctl: URL = "/bin/launchctl"
private let logger = Logger(
  subsystem: bundleIdentifier,
  category: "LaunchctlServerAgent")

/// Drop-in alternative to ``ServerAgent`` that bypasses
/// `SMAppService` and registers the embedded server as a classic
/// per-user `LaunchAgent` in `~/Library/LaunchAgents/`.
///
/// `SMAppService`-spawned helpers go through AMFI's launch
/// constraint check, which rejects ad-hoc-signed binaries with
/// `OS_REASON_CODESIGNING / Launch Constraint Violation`. Classic
/// user-domain `LaunchAgent`s aren't subject to that constraint when
/// the binary itself has no LWCR, so this implementation works for
/// builds where `Scripts/release.sh` strips the launch constraints
/// (the redistributable zip path).
///
/// Tradeoffs vs. ``ServerAgent``:
/// - The agent doesn't appear in System Settings → Login Items.
/// - The plist embeds an absolute path to the server binary, so
///   moving `Galley.app` invalidates the registration. Call
///   ``validateAndRepair()`` on launch to detect that and rewrite
///   the plist against the current bundle.
/// - No `KeepAlive`. If AMFI or the helper itself rejects the
///   spawn, launchd lets it stay dead — better a non-running server
///   than a fast respawn loop that churns ControlCenter.
struct LaunchctlServerAgent {
  /// Label used both as the launchd service name and the plist
  /// filename (`<label>.plist`). Matches ``ServerAgent`` so the two
  /// implementations can't both be active in the same domain.
  let label: String
  /// Absolute path the plist's `Program` key must match for the
  /// installed agent to actually launch this build's server. Derived
  /// from the running `Bundle.main`, so it follows wherever the user
  /// has put `Galley.app`.
  private let helperBinaryPath: String

  init?() {
    guard
      let bundle = Bundle.main.serverBundle,
      let label = bundle.bundleIdentifier,
      let helperBinaryPath = bundle.executableURL?.path
    else {
      return nil
    }
    self.label = label
    self.helperBinaryPath = helperBinaryPath
  }

  var isEnabled: Bool {
    get async {
      guard plistURL.itemExists else {
        return false
      }
      return await isLoadedInLaunchd
    }
  }

  /// Returns the resulting enabled state. On failure, returns the
  /// current state and logs the error.
  @discardableResult
  func setEnabled(_ enabled: Bool) async -> Bool {
    do {
      if enabled {
        try await install()
      } else {
        try await uninstall()
      }
    } catch {
      logToggleFailed(enabled: enabled, error: error)
    }
    return await isEnabled
  }

  /// Call once per launch. If the on-disk plist points at a server
  /// binary that no longer matches the current `Galley.app` bundle
  /// (the user moved the app), rewrite the plist and re-bootstrap.
  /// No-op when the agent isn't installed.
  func validateAndRepair() async {
    guard plistURL.itemExists else {
      return
    }
    let expected = helperBinaryPath
    let installed = installedProgram
    guard installed != expected else { return }

    logger.info("""
      Plist program path drifted (was \
      \(installed ?? "nil", privacy: .public), \
      now \(expected, privacy: .public)) \
      — rewriting and re-bootstrapping.
      """)
    do {
      try writePlist()
      if await isLoadedInLaunchd {
        try? await launchctl.exec("bootout", serviceTarget)
        let result = try await launchctl.execAndCapture(
          "bootstrap", domain, plistURL.path(percentEncoded: false))
        if result.terminationStatus != 0 {
          logger.error("""
            Re-bootstrap after path repair failed (exit \
            \(result.terminationStatus)): \
            \(result.error, privacy: .public)
            """)
        }
      }
    } catch {
      logger.error("""
        Plist repair failed: \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }

  /// Idempotent restart: `launchctl kickstart -k <serviceTarget>`.
  /// `-k` kills the running instance before relaunching, so two
  /// invocations in a row produce exactly one running process. Use
  /// in preference to `NSWorkspace.openApplication` on the relaunch
  /// path — `openApplication` can race itself and spawn duplicates;
  /// launchctl serializes through launchd. Returns true on success,
  /// false when the service isn't bootstrapped (caller can fall
  /// back to a plain spawn).
  @discardableResult
  func kickstart() async -> Bool {
    let result = try? await launchctl.execAndCapture(
      "kickstart", "-k", serviceTarget)
    guard let result, result.terminationStatus == 0 else {
      // Exit 113 = "service not found" — the user hasn't enabled the
      // Login Item, so there's nothing to kickstart. Expected; the
      // caller falls back to `NSWorkspace.openApplication`. Don't
      // spam the log with that case.
      if result?.terminationStatus != 113 {
        logger.notice("""
          kickstart returned non-zero (status=\
          \(result?.terminationStatus ?? -1, privacy: .public)): \
          \(result?.error ?? "<no launchctl>", privacy: .public)
          """)
      }
      return false
    }
    return true
  }

  // MARK: - Private
  private var domain: String {
    "gui/\(getuid())"
  }

  /// Service-target form: `<domain>/<label>`. Passing this to
  /// `launchctl bootout` removes a single service. Passing the bare
  /// domain (`gui/<UID>`) instead — which is what an earlier version
  /// of this file did — boots out the *entire* user GUI domain,
  /// terminating WindowServer/Dock/Finder/ControlCenter etc. and
  /// logging the user out. Don't.
  private var serviceTarget: String {
    "\(domain)/\(label)"
  }

  private var plistURL: URL {
    URL.libraryDirectory
      .appending(path: "LaunchAgents", directoryHint: .isDirectory)
      .appending(path: "\(label).plist")
  }

  private var installedProgram: String? {
    guard
      let data = try? Data(contentsOf: plistURL),
      let dict = try? PropertyListSerialization.propertyList(
        from: data, format: nil) as? [String: Any]
    else { return nil }
    return dict["Program"] as? String
  }

  private var isLoadedInLaunchd: Bool {
    get async {
      let result = try? await launchctl.execAndCapture("print", serviceTarget)
      return result?.terminationStatus == 0
    }
  }

  private func install() async throws {
    // bootout first so install can also act as "switch to a fresh
    // registration" — useful when the bundle path or plist contents
    // have changed since the previous bootstrap. The benign
    // "service-not-found" exit is ignored.
    try? await launchctl.exec("bootout", serviceTarget)

    try writePlist()

    let result = try await launchctl.execAndCapture(
      "bootstrap", domain, plistURL.path(percentEncoded: false))
    guard result.terminationStatus == 0 else {
      throw AgentError.bootstrapFailed(
        exitStatus: result.terminationStatus,
        stderr: result.error)
    }
  }

  private func uninstall() async throws {
    try? await launchctl.exec("bootout", serviceTarget)
    if plistURL.itemExists {
      try plistURL.remove()
    }
  }

  private func writePlist() throws {
    // Deliberately *no* `KeepAlive`. If the helper crashes or AMFI
    // rejects the spawn, launchd will not respawn it. A failed
    // spawn-loop with KeepAlive churns ControlCenter's status-item
    // registration and can destabilize the user session.
    let plist: [String: Any] = [
      "Label": label,
      "Program": helperBinaryPath,
      "RunAtLoad": true
    ]
    try plistURL.parent.createDirectory()
    try PropertyListSerialization
      .data(
        fromPropertyList: plist,
        format: .xml,
        options: 0)
      .write(to: plistURL, options: .atomic)
  }

  // MARK: - launchctl

  private func logToggleFailed(enabled: Bool, error: any Error) {
    logger.error("""
      Failed to \(enabled ? "install" : "uninstall") server agent: \
      \(error.localizedDescription, privacy: .public)
      """)
  }

  enum AgentError: Error, LocalizedError {
    case bootstrapFailed(exitStatus: Int32, stderr: String)

    var errorDescription: String? {
      switch self {
      case .bootstrapFailed(let exitStatus, let stderr):
        return """
          launchctl bootstrap failed (exit \(exitStatus)): \
          \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
          """
      }
    }
  }
}

extension Bundle {
  public var serverBundle: Bundle? {
    url(forResource: "Galley Server", withExtension: "app")
      .flatMap { url in Bundle(url: url) }
  }
}
#endif
