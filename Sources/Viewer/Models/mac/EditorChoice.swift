#if os(macOS)
import AppKit
import Foundation
import GalleyCoreKit
import Observation
import OSLog

/// Disambiguates from ALFoundation's `Logger` type (also imported here
/// for `Process.runAndCapture`). The rest of the file uses `Logger`
/// short-hand via this typealias.
typealias Logger = os.Logger

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
  enum Element: ChoiceValue, Codable, Equatable {
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

    /// User-visible label. Translatable phrases ("Custom URL
    /// Scheme…", "Other Application…") use the literal init so Xcode
    /// extracts them; product / brand names ("BBEdit", "TextMate")
    /// and picked-app filenames go through a runtime
    /// `LocalizationValue` so they stay out of the catalog and
    /// resolve to themselves at lookup time.
    var name: LocalizedStringResource {
      switch self {
      case .preset(let preset):
        return LocalizedStringResource(
          String.LocalizationValue("\(preset.displayName)"))
      case .customURL:
        return "Custom URL Scheme…"
      case .appBundle(let url):
        if let url {
          let basename = url.deletingPathExtension().lastPathComponent
          return LocalizedStringResource(
            String.LocalizationValue("\(basename)"))
        }
        return "Other Application…"
      }
    }

    static let `default`: Element = .preset(.bbedit)
  }

  private(set) var values: [Element]

  /// EditorChoice owns its own UserDefaults persistence,
  /// so the protocol's read-side here returns nil —
  /// nothing for an outside coordinator to mirror to scene storage.
  /// The setter is a no-op for the same reason.
  var persistent: String? {
    get { nil }
    set { _ = newValue }
  }

  @ObservationIgnored private var storedSelected: Element

  var selected: Element {
    get {
      access(keyPath: \.selected)
      return storedSelected
    }
    set {
      // Refuse to land on `.appBundle(nil)`: there is no URL to open
      // a file with. Callers (the settings view) present the picker
      // first, then assign `.appBundle(picked)` only on success.
      if case .appBundle(nil) = newValue { return }

      withMutation(keyPath: \.selected) {
        storedSelected = newValue
      }
      if let index = values.firstIndex(where: { $0.kind == newValue.kind }) {
        values[index] = newValue
      }
      Defaults.shared.editor = storedSelected
    }
  }

  init() {
    var initial: [Element] = EditorPreset.allCases.map { .preset($0) }
    initial.append(.customURL(
      template: EditorPreset.bbedit.urlTemplate ?? ""))
    initial.append(.appBundle(nil))

    let loaded = Defaults.shared.editor
    if let index = initial.firstIndex(where: { $0.kind == loaded.kind }) {
      initial[index] = loaded
    }
    self.values = initial
    self.storedSelected = loaded
  }

  /// URL stored in the `.appBundle` slot, if any. The settings view
  /// reads this to decide whether picking the "Other Application…"
  /// row needs a file picker (slot empty) or can just re-select the
  /// remembered bundle.
  var appBundleURL: URL? {
    for value in values {
      if case .appBundle(let url) = value, let url { return url }
    }
    return nil
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
  return template.substituting(substitutions: [
    "{url}": fileURL.absoluteString
      .addingPercentEncoding(withAllowedCharacters: allowed)
    ?? fileURL.absoluteString,
    "{path}": fileURL.path.percentEncodedForPath,
    "{line}": line.map(String.init) ?? ""
  ])
}

/// Substitutes `{path}` and `{line}` in a shell command argument. No URL
/// encoding — `Process` hands argv straight to the executable. `{line}`
/// defaults to `"1"` when nil so flags like `--line {line}` always have
/// a valid integer to consume.
func substituteCommandArg(
  _ arg: String, fileURL: URL, line: Int?
) -> String {
  arg.substituting(substitutions: [
    "{path}": fileURL.path,
    "{line}": line.map(String.init) ?? "1"
  ])
}

/// Open `fileURL` in the user's chosen editor, optionally jumping to
/// a specific line. URL-template choices fire `NSWorkspace.open(_:)`
/// on the substituted URL; command-style presets launch a CLI tool;
/// the app-bundle choice launches the picked `.app` directly via
/// `NSWorkspace.open(_:withApplicationAt:…)` and silently drops the
/// line argument (no portable way to pass it). `.appBundle(nil)` is
/// a no-op — the panel hasn't been answered yet.
@MainActor
func openFileInEditor(
  _ value: EditorChoice.Element,
  fileURL: URL,
  line: Int? = nil,
  logger: Logger? = nil
) async {
  switch value {
  case .preset(let preset):
    switch preset.invocation {
    case .urlTemplate(let template):
      let urlString = substituteEditorTemplate(
        template, fileURL: fileURL, line: line)
      openURL(urlString, logger: logger)

    case .command(let executable, let args):
      let resolved = args.map {
        substituteCommandArg($0, fileURL: fileURL, line: line)
      }
      await runEditorCommand(
        executable: executable, args: resolved,
        fileURL: fileURL, logger: logger)
    }

  case .customURL(let template):
    let urlString = substituteEditorTemplate(
      template, fileURL: fileURL, line: line)
    openURL(urlString, logger: logger)

  case .appBundle(let appURL):
    guard let appURL else {
      logMissingAppBundle(logger)
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    do {
      _ = try await NSWorkspace.shared.open(
        [fileURL], withApplicationAt: appURL,
        configuration: configuration)
    } catch {
      logAppBundleOpenFailed(
        fileURL: fileURL, appURL: appURL, error: error, logger: logger)
    }
  }
}

@MainActor
private func openURL(_ string: String, logger: Logger?) {
  guard let url = URL(string: string) else {
    logInvalidEditorURL(string, logger: logger)
    return
  }
  if !NSWorkspace.shared.open(url) {
    logEditorURLRejected(string, logger: logger)
  }
}

private func runEditorCommand(
  executable: String, args: [String],
  fileURL: URL, logger: Logger?
) async {
  let executableURL = URL(filePath: executable)
  guard executableURL.isExecutable else {
    logger?.error("""
      Editor command not found or not executable: \
      \(executable, privacy: .public)
      """)
    return
  }
  do {
    let result = try await Process.runAndCapture(
      executableURL,
      with: args as [ProcessArgument],
      streams: ProcessStreams.inMemory)
    if result.terminationStatus != 0 {
      logger?.error("""
        Editor command exited \(result.terminationStatus): \
        \(executable, privacy: .public) for \
        \(fileURL.path, privacy: .public): \
        \(result.error, privacy: .public)
        """)
    }
  } catch {
    logger?.error("""
      Failed to launch editor command \(executable, privacy: .public) \
      for \(fileURL.path, privacy: .public): \
      \(error.localizedDescription, privacy: .public)
      """)
  }
}

private func logMissingAppBundle(_ logger: Logger?) {
  logger?.warning("openFileInEditor: appBundle URL is nil")
}

private func logAppBundleOpenFailed(
  fileURL: URL, appURL: URL, error: any Error, logger: Logger?
) {
  logger?.error("""
    Failed to open \(fileURL.path, privacy: .public) in \
    \(appURL.path, privacy: .public): \
    \(error.localizedDescription, privacy: .public)
    """)
}

private func logInvalidEditorURL(_ string: String, logger: Logger?) {
  logger?.error("""
    Editor URL is not a valid URL: \(string, privacy: .public)
    """)
}

private func logEditorURLRejected(_ string: String, logger: Logger?) {
  logger?.error("""
    No handler accepted editor URL: \(string, privacy: .public)
    """)
}

#endif
