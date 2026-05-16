import Foundation
import ALFoundation

/// The on-disk handshake between Galley Server and its consumers
/// (the Viewer's probe loop, Quicklook, the bundled BBEdit browser
/// scripts). The Server binds to an OS-assigned port at startup and
/// writes the bound port here; consumers read it to discover where
/// the live server is listening.
///
/// One file per scheme: `server-http-port` is always present when
/// the HTTP listener is up; `server-https-port` is published only
/// when the (planned) HTTPS listener is also bound. Consumers that
/// can speak either protocol prefer HTTPS via
/// `preferredEndpointURL`; tools that explicitly want plain HTTP
/// (the Safari / Chrome scripts) read `.http` directly.
///
/// Single integer in plain text — no JSON, no framing — so the
/// bundled AppleScript / shell scripts can read it with one line.
/// Lives next to the Templates folder so its lifecycle and
/// permissions mirror everything else in the suite's Application
/// Support directory.
public enum ServerPortFile {
  /// Which listener a port file corresponds to. Adding a third
  /// scheme later (h2, unix socket, …) is a one-line enum case
  /// extension; consumers that fan out via `preferredEndpointURL`
  /// pick it up automatically.
  public enum Scheme: String, Sendable, CaseIterable {
    case http
    case https

    var filename: String { "server-\(rawValue)-port" }
  }

  public static func url(for scheme: Scheme) -> URL {
    GalleyConstants.applicationSupportDirectory / scheme.filename
  }

  /// Atomically writes the bound port for `scheme`. Creates the
  /// parent directory if missing. The caller — Galley Server's
  /// `PreviewServerController` — invokes this after the listener is
  /// up, so the file is only visible to consumers once `connect()`
  /// against it would actually succeed.
  public static func write(_ port: UInt16, for scheme: Scheme) throws {
    try GalleyConstants.applicationSupportDirectory.createDirectory()
    try String(port)
      .write(to: url(for: scheme), atomically: true, encoding: .utf8)
  }

  /// Returns the port if the file exists and parses; nil otherwise.
  /// `nil` is the canonical "this listener isn't running" signal —
  /// consumers degrade gracefully (Quicklook → in-process render,
  /// Viewer probe → `.stopped`, browser scripts → user-visible
  /// error).
  public static func read(for scheme: Scheme) -> UInt16? {
    guard let text = try? String(
      contentsOf: url(for: scheme), encoding: .utf8)
    else { return nil }
    return UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Removes the file. Called by the Server when a listener stops
  /// so stale values don't outlive the process; safe to call when
  /// the file doesn't exist.
  public static func clear(for scheme: Scheme) {
    try? FileManager.default.removeItem(at: url(for: scheme))
  }

  /// `http://127.0.0.1:<port>/` / `https://127.0.0.1:<port>/` for
  /// the listener currently published under `scheme`, or nil when
  /// the file is missing/unparseable.
  public static func endpointURL(for scheme: Scheme) -> URL? {
    guard let port = read(for: scheme) else { return nil }
    var components = URLComponents()
    components.scheme = scheme.rawValue
    components.host = GalleyConstants.defaultHost
    components.port = Int(port)
    return components.url
  }

  /// HTTPS endpoint if it's published, otherwise HTTP. Use this
  /// from consumers (Viewer, Quicklook) that can speak either
  /// protocol and prefer the pinned channel when it's available.
  /// Returns nil only when neither file is present.
  public static var preferredEndpointURL: URL? {
    endpointURL(for: .https) ?? endpointURL(for: .http)
  }
}
