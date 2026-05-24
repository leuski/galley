import ALFoundation
import Darwin
import Foundation
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "ServerPortFile")

/// The on-disk handshake between Galley Server and its consumers
/// (the Viewer's probe loop, Quicklook, the bundled BBEdit browser
/// scripts). The Server binds to an OS-assigned port at startup and
/// writes the bound port to one of these files; consumers read it
/// to discover where the live server is listening.
///
/// One file per scheme, exposed as the `http` and `https` constants.
/// `server-http-port` is always present when the HTTP listener is
/// up; `server-https-port` is published only when the HTTPS listener
/// is also bound. The HTTP listener is loopback-only (`127.0.0.1`)
/// regardless of bind mode, so same-machine consumers (Viewer,
/// Quicklook, BBEdit scripts) read HTTP via `preferredEndpointURL`.
/// HTTPS is reserved for the LAN-reachable Kosmos bridge path
/// consumed by AVP.
///
/// Single integer in plain text — no JSON, no framing — so the
/// bundled AppleScript / shell scripts can read it with one line.
/// Lives next to the Templates folder so its lifecycle and
/// permissions mirror everything else in the suite's Application
/// Support directory.
///
/// The `.http` file doubles as the single-instance sentinel: callers
/// that pass `lock: true` to `write(_:lock:)` take a process-wide
/// `flock(LOCK_EX | LOCK_NB)` on it before publishing the port, so a
/// second Galley Server process trying to claim the same file gets
/// `LockedByAnotherProcess`. The descriptor is held for the process
/// lifetime — macOS releases the flock automatically on exit or
/// crash, and there is intentionally no `release()` path that could
/// drop the lock while the server is still running.
public struct ServerPortFile: Hashable, Sendable {
  /// Which listener this file corresponds to. Internal because the
  /// public surface picks an instance through one of the static
  /// constants below; the scheme name is observable via `urlScheme`.
  fileprivate enum Scheme: String, Sendable, CaseIterable {
    case http
    case https

    var filename: String { "server-\(rawValue)-port" }
  }

  /// Thrown by `write(_:lock:)` when another live process already
  /// holds the flock on the file. The caller — Galley Server's
  /// `PreviewServerController` — maps this to the user-facing
  /// "another Galley Server is already running" failure state.
  public struct LockedByAnotherProcess: Error, Sendable {}

  fileprivate let scheme: Scheme

  /// HTTP port file. Locked-write target — the file doubles as the
  /// single-instance sentinel.
  public static let http = ServerPortFile(scheme: .http)

  /// HTTPS port file. Plain atomic write; no lock. Present only
  /// when the LAN-reachable HTTPS listener is also bound.
  public static let https = ServerPortFile(scheme: .https)

  /// Both port files, in preferred-read order (HTTP first).
  public static let all: [ServerPortFile] = [.http, .https]

  /// URL scheme this file corresponds to (`"http"` / `"https"`).
  public var urlScheme: String { scheme.rawValue }

  /// On-disk path of the port file.
  public var url: URL {
    GalleyConstants.applicationSupportDirectory / scheme.filename
  }

  /// Writes the bound port to disk. Creates the parent directory if
  /// missing. The caller — Galley Server's `PreviewServerController`
  /// — invokes this after the listener is up, so the file is only
  /// visible to consumers once `connect()` against it would actually
  /// succeed.
  ///
  /// `lock: false` (default, and the only mode used for `.https`):
  /// plain atomic write via temp-file + rename. No flock.
  ///
  /// `lock: true` (used for `.http`): acquires a process-wide
  /// `flock(LOCK_EX | LOCK_NB)` on the file before writing; throws
  /// `LockedByAnotherProcess` if another live process already owns
  /// it. Idempotent within a process — repeated calls reuse the
  /// held descriptor and just rewrite the port through it, so a
  /// later `start()` (e.g. for a bind-mode flip) keeps the same
  /// lock. Under xctest the lock is skipped so the user's running
  /// Server doesn't block the test suite; the file is still written
  /// atomically.
  public func write(_ port: UInt16, lock: Bool = false) throws {
    if lock && !Self.isRunningUnderXCTest {
      try writeLocked(port)
    } else {
      try writeAtomic(port)
    }
  }

  /// Returns the port if the file exists and parses; nil otherwise.
  /// `nil` is the canonical "this listener isn't running" signal —
  /// consumers degrade gracefully (Quicklook → in-process render,
  /// Viewer probe → `.stopped`, browser scripts → user-visible
  /// error).
  public func read() -> UInt16? {
    guard let text = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    return UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Publishes "this listener is no longer serving" by zeroing the
  /// file. When this process holds the flock on the file (i.e.
  /// `lock: true` was used to write it), the file is truncated in
  /// place so the lock survives the stop/start cycle. Otherwise
  /// the file is unlinked. Safe to call when the file doesn't exist.
  public func clear() {
    Holder.shared.clear(scheme: scheme)
  }

  /// `http://127.0.0.1:<port>/` / `https://127.0.0.1:<port>/` for
  /// this listener, or nil when the file is missing/unparseable.
  public var endpointURL: URL? {
    guard let port = read() else { return nil }
    var components = URLComponents()
    components.scheme = scheme.rawValue
    components.host = GalleyConstants.defaultHost
    components.port = Int(port)
    return components.url
  }

  /// HTTP endpoint if it's published, otherwise HTTPS. Use this
  /// from same-machine consumers (Viewer, Quicklook, BBEdit scripts)
  /// that hit the loopback Server — HTTP is the canonical loopback
  /// path now that the Server pins its HTTP listener to `127.0.0.1`
  /// independent of LAN mode. HTTPS is a legacy fallback for the
  /// rare case where HTTP failed to bind but HTTPS came up.
  /// Returns nil only when neither file is present.
  public static var preferredEndpointURL: URL? {
    http.endpointURL ?? https.endpointURL
  }

  // MARK: - Internals

  private func writeAtomic(_ port: UInt16) throws {
    try GalleyConstants.applicationSupportDirectory.createDirectory()
    try String(port).write(to: url, atomically: true, encoding: .utf8)
  }

  private func writeLocked(_ port: UInt16) throws {
    let fileDesc = try Holder.shared.ensureLocked(scheme: scheme)
    let payload = "\(port)\n"
    try payload.withCString { ptr in
      let length = strlen(ptr)
      guard ftruncate(fileDesc, 0) == 0,
            lseek(fileDesc, 0, SEEK_SET) >= 0,
            Darwin.write(fileDesc, ptr, length) == length
      else {
        let savedErrno = errno
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(savedErrno))
      }
    }
  }

  private static var isRunningUnderXCTest: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil
      || env["XCTestBundlePath"] != nil
      || env["XCTestSessionIdentifier"] != nil
  }

  /// Process-wide owner of the per-scheme held file descriptors used
  /// by the locked write path. State guarded by `NSLock`; access
  /// only via the methods below.
  private final class Holder: @unchecked Sendable {
    static let shared = Holder()

    private let stateLock = NSLock()
    private var holdingFD: [Scheme: Int32] = [:]

    func ensureLocked(scheme: Scheme) throws -> Int32 {
      stateLock.lock()
      defer { stateLock.unlock() }

      if let existing = holdingFD[scheme] { return existing }

      try GalleyConstants.applicationSupportDirectory.createDirectory()
      let path = (GalleyConstants.applicationSupportDirectory / scheme.filename)
        .path
      let fileDesc = open(path, O_RDWR | O_CREAT, 0o644)
      guard fileDesc >= 0 else {
        let savedErrno = errno
        log.error("""
          open(\(path, privacy: .public)) failed: \
          errno=\(savedErrno, privacy: .public)
          """)
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(savedErrno))
      }

      if flock(fileDesc, LOCK_EX | LOCK_NB) != 0 {
        let savedErrno = errno
        close(fileDesc)
        if savedErrno == EWOULDBLOCK {
          log.notice("""
            Another Server process holds \
            \(path, privacy: .public). Refusing to start.
            """)
          throw LockedByAnotherProcess()
        }
        log.error("""
          flock(LOCK_EX|LOCK_NB) failed: errno=\
          \(savedErrno, privacy: .public)
          """)
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(savedErrno))
      }

      holdingFD[scheme] = fileDesc
      return fileDesc
    }

    func clear(scheme: Scheme) {
      stateLock.lock()
      let heldFD = holdingFD[scheme]
      stateLock.unlock()

      let target = GalleyConstants.applicationSupportDirectory
        / scheme.filename
      if let fileDesc = heldFD {
        // Keep the lock alive across stop/start cycles by zeroing
        // the file in place rather than unlinking it.
        _ = ftruncate(fileDesc, 0)
        return
      }

      do {
        try target.remove()
      } catch CocoaError.fileNoSuchFile {
        // Already absent — expected on first stop or repeat clears.
      } catch {
        log.debug("""
          Couldn't remove \(target.lastPathComponent, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
  }
}
