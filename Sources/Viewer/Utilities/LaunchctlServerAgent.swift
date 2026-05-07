import Foundation
import os
import GalleyCoreKit
import ALFoundation

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
enum LaunchctlServerAgent {
  /// Label used both as the launchd service name and the plist
  /// filename (`<label>.plist`). Matches ``ServerAgent`` so the two
  /// implementations can't both be active in the same domain.
  static let label = "net.leuski.galley.server"

  static var isEnabled: Bool {
    get async {
      guard FileManager.default.fileExists(atPath: plistURL.path) else {
        return false
      }
      return await isLoadedInLaunchd
    }
  }

  /// Returns the resulting enabled state. On failure, returns the
  /// current state and logs the error.
  @discardableResult
  static func setEnabled(_ enabled: Bool) async -> Bool {
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
  static func validateAndRepair() async {
    guard FileManager.default.fileExists(atPath: plistURL.path) else {
      return
    }
    let expected = helperBinaryPath
    let installed = installedProgram
    guard installed != expected else { return }

    logger.info("""
      Plist program path drifted (was \
      \(installed ?? "nil", privacy: .public), \
      now \(expected, privacy: .public)) — rewriting and re-bootstrapping.
      """)
    do {
      try writePlist()
      if await isLoadedInLaunchd {
        _ = try? await launchctl("bootout", serviceTarget)
        let result = try await launchctl(
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

  // MARK: - Private

  private static let logger = Logger(
    subsystem: bundleIdentifier,
    category: "LaunchctlServerAgent")

  private static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")

  private static var domain: String {
    "gui/\(getuid())"
  }

  /// Service-target form: `<domain>/<label>`. Passing this to
  /// `launchctl bootout` removes a single service. Passing the bare
  /// domain (`gui/<UID>`) instead — which is what an earlier version
  /// of this file did — boots out the *entire* user GUI domain,
  /// terminating WindowServer/Dock/Finder/ControlCenter etc. and
  /// logging the user out. Don't.
  private static var serviceTarget: String {
    "\(domain)/\(label)"
  }

  private static var plistURL: URL {
    URL.libraryDirectory
      .appending(path: "LaunchAgents", directoryHint: .isDirectory)
      .appending(path: "\(label).plist")
  }

  /// Absolute path the plist's `Program` key must match for the
  /// installed agent to actually launch this build's server. Derived
  /// from the running `Bundle.main`, so it follows wherever the user
  /// has put `Galley.app`.
  private static var helperBinaryPath: String {
    Bundle.main.bundleURL
      .appending(path: "Contents/Resources/Galley Server.app")
      .appending(path: "Contents/MacOS/Galley Server")
      .path(percentEncoded: false)
  }

  private static var installedProgram: String? {
    guard
      let data = try? Data(contentsOf: plistURL),
      let dict = try? PropertyListSerialization.propertyList(
        from: data, format: nil) as? [String: Any]
    else { return nil }
    return dict["Program"] as? String
  }

  private static var isLoadedInLaunchd: Bool {
    get async {
      let result = try? await launchctl("print", serviceTarget)
      return result?.terminationStatus == 0
    }
  }

  private static func install() async throws {
    // bootout first so install can also act as "switch to a fresh
    // registration" — useful when the bundle path or plist contents
    // have changed since the previous bootstrap. The benign
    // "service-not-found" exit is ignored.
    _ = try? await launchctl("bootout", serviceTarget)

    try writePlist()

    let result = try await launchctl(
      "bootstrap", domain, plistURL.path(percentEncoded: false))
    guard result.terminationStatus == 0 else {
      throw AgentError.bootstrapFailed(
        exitStatus: result.terminationStatus,
        stderr: result.error)
    }
  }

  private static func uninstall() async throws {
    _ = try? await launchctl("bootout", serviceTarget)
    if FileManager.default.fileExists(atPath: plistURL.path) {
      try FileManager.default.removeItem(at: plistURL)
    }
  }

  private static func writePlist() throws {
    // Deliberately *no* `KeepAlive`. If the helper crashes or AMFI
    // rejects the spawn, launchd will not respawn it. A failed
    // spawn-loop with KeepAlive churns ControlCenter's status-item
    // registration and can destabilize the user session.
    let plist: [String: Any] = [
      "Label": label,
      "Program": helperBinaryPath,
      "RunAtLoad": true
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0)
    try FileManager.default.createDirectory(
      at: plistURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try data.write(to: plistURL, options: .atomic)
  }

  // MARK: - launchctl

  /// Thin wrapper around `Process.runAndCapture` for `/bin/launchctl`
  /// invocations. Exists so callers don't repeat the executable URL
  /// and the cast to `[ProcessArgument]`.
  @discardableResult
  private static func launchctl(
    _ args: String...
  ) async throws -> Process.ProcessResult {
    try await Process.runAndCapture(
      launchctlURL,
      with: args as [ProcessArgument])
  }

  private static func logToggleFailed(enabled: Bool, error: any Error) {
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
