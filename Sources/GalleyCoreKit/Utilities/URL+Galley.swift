import Foundation
import KosmosAppKit

/// Tabs of the Viewer's Settings scene. Carried on inbound
/// `galley://settings?tab=<id>` URLs so external callers (e.g. the
/// Server app's menu bar) can deep-link into a specific pane.
public enum SettingsTab: String, Sendable, CaseIterable {
  case general
  case markdown
  case server
}

public struct DocumentTarget: Sendable, Equatable, Codable,
                                  CustomStringConvertible
{
  public let url: URL
  public let scrollLine: Int?

  public var description: String {
    "\(url)\(scrollLine.map(\.description) ?? "")"
  }

  public init(url: URL, scrollLine: Int? = nil) {
    self.url = url
    self.scrollLine = scrollLine
  }

  public init?(components: URLComponents?) {
    guard let components else {
      return nil
    }
    let path = components.path
    guard !path.isEmpty else {
      return nil
    }
    let fileURL = URL(fileURLWithPath: path)
    let line = components.queryItems?
      .first(where: { $0.name == "line" })
      .flatMap { $0.value }
      .flatMap(Int.init)
      .flatMap { $0 > 0 ? $0 : nil }
    self.init(url: fileURL, scrollLine: line)
  }

  public func url(scheme: String) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.path = url.path
    if let line = scrollLine {
      components.queryItems = [URLQueryItem(name: "line", value: "\(line)")]
    }
    guard let url = components.url else {
      preconditionFailure("settingsURL components produced no URL")
    }
    return url
  }
}

/// Outcome of normalizing a single inbound URL.
public enum GalleyRequest: Sendable, Equatable, CustomStringConvertible {
  /// `galley://settings[?tab=<id>]` — caller should invoke
  /// `openSettings()` and, if `tab` is non-nil, switch the Settings
  /// scene to that pane.
  case openSettings(SettingsTab?)
  /// Plain document open. `scrollLine` carries any `?line=N` from
  /// the source `galley://path?line=N` URL; nil for non-galley
  /// inbound URLs.
  case document(DocumentTarget)

  public var description: String {
    url.absoluteString
  }

  /// Document scheme — `galley://<path>`, routed to the document
  /// `WindowGroup` (plain `file://` documents route there too).
  public static let scheme: String = "galley"
  /// Settings scene scheme — its own scheme (not a `galley://` host) so
  /// the document `WindowGroup` claims `galley://` cleanly while the
  /// Settings scene claims `galley-settings://` via `handlesExternalEvents`.
  public static let settingsScheme: String = "galley-settings"

  public var url: URL {
    switch self {
    case .document(let info):
      guard info.url.isFileURL else {
        return info.url
      }
      return info.url(scheme: Self.scheme)

    case .openSettings(let tab):
      var components = URLComponents()
      components.scheme = Self.settingsScheme
      components.host = ""
      if let tab {
        components.queryItems = [URLQueryItem(name: "tab", value: tab.rawValue)]
      }
      guard let url = components.url else {
        preconditionFailure("settingsURL components produced no URL")
      }
      return url
    }
  }

  private static func parse(_ url: URL) -> GalleyRequest? {
    let scheme = url.scheme?.lowercased()
    let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false)
    // Settings has its own scheme — recognized regardless of path.
    if scheme == Self.settingsScheme {
      let tab = components?.queryItems?
        .first(where: { $0.name == "tab" })
        .flatMap { $0.value }
        .flatMap { SettingsTab(rawValue: $0.lowercased()) }
      return .openSettings(tab)
    }
    // Everything else is a document. `galley://<path>` parses through
    // `DocumentTarget` (line-number support); other schemes (file://,
    // http(s)://) pass through unchanged.
    guard scheme == Self.scheme else {
      return .document(.init(url: url))
    }
    return DocumentTarget.init(components: components)
      .map { target in .document(target) }
  }

  public init?(from url: URL) {
    if let action = Self.parse(url) {
      self = action
    } else {
      return nil
    }
  }
}

public extension URL {

  var galleyRequest: GalleyRequest? {
    GalleyRequest(from: self)
  }

  /// Scheme the Help scene claims via `handlesExternalEvents`. Help docs
  /// are fired at the app as `galley-help://<bundle-path>` so SwiftUI
  /// routes them to the singleton Help window — distinct from the
  /// document `galley://` scheme so they never become document windows.
  static let galleyHelpScheme: String = "galley-help"

  /// Build the `galley-help://<path>` URL for a bundled help document.
  static func galleyHelp(forBundleFile fileURL: URL) -> URL {
    var components = URLComponents()
    components.scheme = galleyHelpScheme
    components.host = ""
    components.path = fileURL.path
    return components.url ?? fileURL
  }

  /// If this is a `galley-help://<path>` URL, the bundled file it points
  /// at; otherwise nil. Used by the Help scene's `onOpenURL`.
  var galleyHelpFileURL: URL? {
    guard scheme?.lowercased() == Self.galleyHelpScheme else { return nil }
    let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
    guard let path = components?.path, !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// Self with any query and fragment stripped. Pure; safe on any URL.
  var withoutQueryOrFragment: URL {
    guard var components = URLComponents(
      url: self, resolvingAgainstBaseURL: false)
    else { return self }
    components.query = nil
    components.fragment = nil
    return components.url ?? self
  }

  /// Tokens a document window advertises via SwiftUI
  /// `handlesExternalEvents(preferring:)` so a repeat-open of the same
  /// document routes back to the window already showing it instead of
  /// spawning a duplicate. Match tokens are prefix-matched against the
  /// incoming URL's `absoluteString`, so:
  ///
  ///   - the query is dropped, so `galley://p?line=2` still routes to
  ///     the window showing `galley://p`;
  ///   - a standardized file-URL form is added when it differs from
  ///     the original (symlinked or `..`-laden paths);
  ///   - the `galley://` form is added because re-opens arrive in that
  ///     scheme (BBEdit's preview script, in-process menu opens) while
  ///     the window's bound value is always a `file://` URL.
  ///
  /// Returns an empty array for a window with no bound URL (the empty
  /// bootstrap window), which then competes only as an `allowing`
  /// catch-all.
  var galleyPreferringTokens: [String] {
    var tokens: [String] = []
    func add(_ url: URL) {
      let string = url.withoutQueryOrFragment.absoluteString
      if !string.isEmpty, !tokens.contains(string) { tokens.append(string) }
    }
    add(self)
    if isFileURL {
      add(standardizedFileURL)
      // The scheme re-opens actually arrive in (file URL → galley://).
      add(GalleyRequest.document(
        DocumentTarget(url: standardizedFileURL)).url)
    }
    return tokens
  }

  /// Resolves the kit framework's bundled templates folder.
  ///
  /// The bundled templates ship inside a `Templates.bundle` directory
  /// because Xcode 16's synchronized root groups otherwise flatten
  /// resource directory structure when copying — a `.bundle`-suffixed
  /// folder is treated as an opaque wrapper and copied whole. Inside
  /// the wrapper we keep one folder per template (`Default/`,
  /// future `Tufte/`, etc.) using the same folder shape user
  /// templates use.
  static let bundleTemplatesDirectoryURL: URL = {
    Bundle.galleyCoreKit.url(
      forResource: "Templates", withExtension: "bundle")
    !! "GalleyCoreKit bundle missing Templates.bundle wrapper"
  }()
}

extension URL {
  public var galleyPreview: URL {
    appending(path: RouteNames.preview)
  }

  /// Construct a tunnel URL for a document or asset at a POSIX path.
  /// `path` must begin with `/`. Returns nil only on malformed input.
  ///
  /// `URL.appending(path:)` percent-encodes its argument, so the
  /// input is the raw filesystem path — never `percentEncodedForPath`,
  /// or `%` itself ends up as `%25` on the wire.
  public func galleyPreviewURL(forFile path: String) -> URL? {
    guard path.hasPrefix("/") else { return nil }
    return galleyPreview.appending(path: path)
  }

  public func galleyTemplate(id: String) -> URL {
    appending(path: RouteNames.template).appending(path: id)
  }

  /// `<self>/preview` — the route prefix for previewed documents.
  /// Pass `documentPath` to point at a specific document.
  public func appendingPreview(_ documentURL: URL) -> URL {
    galleyPreview.appending(path: documentURL.safe.path)
  }

  /// `<self>/template/<id>` — the route prefix for template assets.
  /// Pass `file` to point at a specific asset.
  public func appendingTemplate(id: String, file documentURL: URL) -> URL {
    galleyTemplate(id: id).appending(path: documentURL.safe.path)
  }
}
