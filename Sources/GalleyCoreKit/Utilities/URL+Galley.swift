import Foundation
import ALFoundation

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

  private static let scheme: String = "galley"
  private static let settingsHost: String = "settings"

  public var url: URL {
    switch self {
    case .document(let info):
      guard info.url.isFileURL else {
        return info.url
      }
      return info.url(scheme: Self.scheme)

    case .openSettings(let tab):
      var components = URLComponents()
      components.scheme = Self.scheme
      components.host = Self.settingsHost
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
    guard url.scheme?.lowercased() == Self.scheme else {
      return .document(.init(url: url))
    }
    let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false)
    if url.host?.lowercased() == Self.settingsHost {
      let tab = components?.queryItems?
        .first(where: { $0.name == "tab" })
        .flatMap { $0.value }
        .flatMap { SettingsTab(rawValue: $0.lowercased()) }
      return .openSettings(tab)
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
