import Foundation

/// Outcome of normalizing a single inbound URL.
public enum GalleyURLAction: Sendable, Equatable {
  /// `galley://settings` — caller should invoke `openSettings()`.
  case openSettings
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
    if host?.lowercased() == "settings" {
      return .openSettings
    }
    guard let components = URLComponents(
      url: self,
      resolvingAgainstBaseURL: false)
    else {
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
}
