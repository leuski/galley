import Foundation
import ServiceManagement
import os
import GalleyCoreKit

/// Wraps `SMAppService.agent` so the rest of the Viewer can ask
/// whether the Markdown Preview Server is registered to launch
/// without importing ServiceManagement directly.
///
/// The agent plist must reside in the Viewer bundle at
/// `Contents/Library/LaunchAgents/net.leuski.galley.server.plist`.
enum ServerAgent {
  @MainActor
  private static let service = SMAppService.agent(
    plistName: "net.leuski.galley.server.plist")

  private static let logger = Logger(
    subsystem: bundleIdentifier,
    category: "ServerAgent")

  @MainActor
  static var isEnabled: Bool {
    service.status == .enabled
  }

  /// Returns the resulting enabled state. On failure, returns the
  /// current state and logs the error.
  @MainActor
  @discardableResult
  static func setEnabled(_ enabled: Bool) -> Bool {
    do {
      if enabled {
        if service.status != .enabled {
          try service.register()
        }
      } else {
        if service.status != .notRegistered {
          try service.unregister()
        }
      }
    } catch {
      logToggleFailed(enabled: enabled, error: error)
    }
    return isEnabled
  }

  private static func logToggleFailed(enabled: Bool, error: any Error) {
    logger.error("""
      Failed to \(enabled ? "register" : "unregister") \
      server agent: \(error.localizedDescription)
      """)
  }
}
