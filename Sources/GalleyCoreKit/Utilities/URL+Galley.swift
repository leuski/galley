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

/// Outcome of normalizing a single inbound URL.
public enum GalleyURLAction: Sendable, Equatable {
  /// `galley://settings[?tab=<id>]` — caller should invoke
  /// `openSettings()` and, if `tab` is non-nil, switch the Settings
  /// scene to that pane.
  case openSettings(SettingsTab?)
  /// Plain document open. `scrollLine` carries any `?line=N` from
  /// the source `galley://path?line=N` URL; nil for non-galley
  /// inbound URLs.
  case document(URL, scrollLine: Int?)
  /// Could not be parsed; caller should log and pass through to the
  /// default open path.
  case unparseable(URL)
}

/// Pure normalization of inbound URLs from `application(_:open:)` and
/// the custom `galley://` scheme into the canonical file URL the
/// dispatch pipeline expects.
///
/// `galley://settings` is recognized and surfaced separately so the
/// caller can route it to SwiftUI's `openSettings()` instead of
/// trying to open it as a document.

public extension URL {
  var galleyAction: GalleyURLAction {
    let scheme = scheme?.lowercased()
    guard scheme == "galley" else {
      return .document(self, scrollLine: nil)
    }
    let components = URLComponents(
      url: self,
      resolvingAgainstBaseURL: false)
    if host?.lowercased() == "settings" {
      let tab = components?.queryItems?
        .first(where: { $0.name == "tab" })
        .flatMap { $0.value }
        .flatMap { SettingsTab(rawValue: $0.lowercased()) }
      return .openSettings(tab)
    }
    guard let components else {
      return .unparseable(self)
    }
    let path = components.path
    guard !path.isEmpty else {
      return .unparseable(self)
    }
    let fileURL = URL(fileURLWithPath: path)
    let line = components.queryItems?
      .first(where: { $0.name == "line" })
      .flatMap { $0.value }
      .flatMap(Int.init)
      .flatMap { $0 > 0 ? $0 : nil }
    return .document(fileURL, scrollLine: line)
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
