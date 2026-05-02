import AppKit
import Foundation
import GalleyCoreKit
import Observation
import os
import UniformTypeIdentifiers

/// A built-in editor whose URL scheme + line-jump format we know.
enum EditorPreset: String, Codable, CaseIterable, Identifiable,
                   Hashable, Sendable
{
  case bbedit
  case textmate
  case vscode
  case sublime
  case zed

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .bbedit:   return "BBEdit"
    case .textmate: return "TextMate"
    case .vscode:   return "Visual Studio Code"
    case .sublime:  return "Sublime Text"
    case .zed:      return "Zed"
    }
  }

  /// URL template with `{url}`, `{path}`, `{line}` placeholders.
  /// `{url}` is the percent-encoded `file://…`; `{path}` is the
  /// percent-encoded absolute filesystem path; `{line}` is the
  /// integer line number, or empty when unknown.
  var template: String {
    switch self {
    case .bbedit:   return "x-bbedit://open?url={url}&line={line}"
    case .textmate: return "txmt://open?url={url}&line={line}"
    case .vscode:   return "vscode://file{path}:{line}"
    case .sublime:  return "subl://open?url={url}&line={line}"
    case .zed:      return "zed://file{path}:{line}"
    }
  }
}

/// Choice model over the user's editor target. Drives both cmd-click
/// → editor and File > Open in Editor. `values` is mutable in-memory
/// state so the customURL template and appBundle URL survive mode
/// switches within a session — a new selection rewrites the matching
/// slot in `values`. Across launches only the last `selected` is
/// persisted; if it isn't in customURL/appBundle mode at quit time,
/// those slots reset to defaults on next launch.
@Observable
@MainActor
final class EditorChoice: ChoiceModel {
  enum Element: ChoiceValue, Codable {
    case preset(EditorPreset)
    case customURL(template: String)
    case appBundle(URL?)

    /// Discriminator used to find the matching slot in `values` when
    /// the setter rewrites it. Two values with the same `kind` belong
    /// in the same slot regardless of their associated payload.
    enum Kind: Hashable, Sendable {
      case preset(EditorPreset)
      case customURL
      case appBundle
    }

    var kind: Kind {
      switch self {
      case .preset(let preset): return .preset(preset)
      case .customURL:          return .customURL
      case .appBundle:          return .appBundle
      }
    }

    var name: String {
      switch self {
      case .preset(let preset):
        return preset.displayName
      case .customURL:
        return "Custom URL Scheme…"
      case .appBundle(let url):
        if let url {
          return url.deletingPathExtension().lastPathComponent
        }
        return "Other Application…"
      }
    }

    static let `default`: Element = .preset(.bbedit)
  }

  private(set) var values: [Element]

  /// EditorChoice owns its own UserDefaults persistence (see
  /// `persist()`), so the protocol's read-side here returns nil —
  /// nothing for an outside coordinator to mirror to scene storage.
  var persistent: String? { nil }

  @ObservationIgnored private var storedSelected: Element

  var selected: Element {
    get {
      access(keyPath: \.selected)
      return storedSelected
    }
    set {
      let resolved: Element
      switch newValue {
      case .appBundle(nil):
        // Re-use whichever URL the appBundle slot already has if it
        // has one; otherwise prompt. A cancelled prompt refuses the
        // assignment so the previous selection stays put.
        if let existing = currentAppBundleURL {
          resolved = .appBundle(existing)
        } else if let picked = pickAppBundle() {
          resolved = .appBundle(picked)
        } else {
          return
        }
      default:
        resolved = newValue
      }
      withMutation(keyPath: \.selected) {
        storedSelected = resolved
      }
      if let index = values.firstIndex(where: { $0.kind == resolved.kind }) {
        values[index] = resolved
      }
      persist()
    }
  }

  @ObservationIgnored private let key: String
  @ObservationIgnored private let pickAppBundle: @MainActor () -> URL?

  init(
    key: String = "\(keyPrefix).editorChoice",
    pickAppBundle: @escaping @MainActor () -> URL? = EditorChoice
      .defaultPickAppBundle
  ) {
    self.key = key
    self.pickAppBundle = pickAppBundle

    var initial: [Element] = EditorPreset.allCases.map { .preset($0) }
    initial.append(.customURL(template: EditorPreset.bbedit.template))
    initial.append(.appBundle(nil))

    let loaded = Self.load(key: key) ?? .default
    if let index = initial.firstIndex(where: { $0.kind == loaded.kind }) {
      initial[index] = loaded
    }
    self.values = initial
    self.storedSelected = loaded
  }

  private var currentAppBundleURL: URL? {
    for value in values {
      if case .appBundle(let url) = value, let url { return url }
    }
    return nil
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(storedSelected) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }

  private static func load(key: String) -> Element? {
    guard let data = UserDefaults.standard.data(forKey: key),
          let decoded = try? JSONDecoder().decode(Element.self, from: data)
    else { return nil }
    return decoded
  }

  /// Default app-bundle picker — runs `NSOpenPanel` filtered to
  /// `.app` bundles. Returns nil if the user cancels.
  static func defaultPickAppBundle() -> URL? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url
  }
}

// MARK: - Opening files

/// Substitutes `{url}`, `{path}`, `{line}` in a URL template.
/// Values are percent-encoded for their intended URL position.
func substituteEditorTemplate(
  _ template: String,
  fileURL: URL,
  line: Int?
) -> String {
  let allowed = CharacterSet.urlQueryAllowed
    .subtracting(CharacterSet(charactersIn: "&=+?#"))
  let urlEncoded = fileURL.absoluteString
    .addingPercentEncoding(withAllowedCharacters: allowed)
  ?? fileURL.absoluteString
  let pathEncoded = fileURL.path
    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
  ?? fileURL.path
  let lineStr = line.map(String.init) ?? ""
  return template
    .replacingOccurrences(of: "{url}", with: urlEncoded)
    .replacingOccurrences(of: "{path}", with: pathEncoded)
    .replacingOccurrences(of: "{line}", with: lineStr)
}

/// Open `fileURL` in the user's chosen editor, optionally jumping to
/// a specific line. URL-template choices fire `NSWorkspace.open(_:)`
/// on the substituted URL; the app-bundle choice launches the picked
/// `.app` directly via `NSWorkspace.open(_:withApplicationAt:…)` and
/// silently drops the line argument (no portable way to pass it).
/// `.appBundle(nil)` is a no-op — the panel hasn't been answered yet.
@MainActor
func openFileInEditor(
  _ value: EditorChoice.Element,
  fileURL: URL,
  line: Int? = nil,
  logger: Logger? = nil
) async {
  switch value {
  case .preset(let preset):
    let urlString = substituteEditorTemplate(
      preset.template, fileURL: fileURL, line: line)
    openURL(urlString, logger: logger)

  case .customURL(let template):
    let urlString = substituteEditorTemplate(
      template, fileURL: fileURL, line: line)
    openURL(urlString, logger: logger)

  case .appBundle(let appURL):
    guard let appURL else {
      logger?.warning("openFileInEditor: appBundle URL is nil")
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    do {
      _ = try await NSWorkspace.shared.open(
        [fileURL], withApplicationAt: appURL,
        configuration: configuration)
    } catch {
      logger?.error("""
        Failed to open \(fileURL.path, privacy: .public) in \
        \(appURL.path, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
    }
  }
}

@MainActor
private func openURL(_ string: String, logger: Logger?) {
  guard let url = URL(string: string) else {
    logger?.error("""
      Editor URL is not a valid URL: \(string, privacy: .public)
      """)
    return
  }
  if !NSWorkspace.shared.open(url) {
    logger?.error("""
      No handler accepted editor URL: \(string, privacy: .public)
      """)
  }
}
