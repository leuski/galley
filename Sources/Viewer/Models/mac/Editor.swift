//
//  Editor.swift
//  Galley
//
//  Created by Anton Leuski on 7/1/26.
//

#if os(macOS)
import AppKit
import Foundation
import GalleyCoreKit
import OSLog

private let logger = Logger(
  subsystem: bundleIdentifier, category: "Editor")

private func bundleURL(_ bundleIdentifiers: [String]) -> URL? {
  bundleIdentifiers
    .lazy
    .compactMap { id in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }
    .first
}

enum InvocationStyle: Sendable, Hashable {
  /// `{url}`, `{path}`, `{line}` placeholders, percent-encoded for
  /// their position in the URL.
  case urlTemplate(String)
  /// Executable + argument list. `{path}` and `{line}` placeholders
  /// in `args` substitute raw (no URL encoding); `{line}` substitutes
  /// to `1` when the caller passes nil.
  case command(executable: String, args: [String])
  case open
}

enum ScriptInstallError: LocalizedError {
  case sourceMissing
  case copyFailed(URL, any Error)

  var errorDescription: String? {
    switch self {
    case .sourceMissing:
      "The bundled Scripts folder is missing from the application."
    case .copyFailed(let url, let error):
        """
        Failed to install \(url.lastPathComponent): \
        \(error.localizedDescription)
        """
    }
  }
}

@MainActor
struct Editor: ChoiceValue, SectionedChoiceValue
{
  static let customURLScheme = Editor(
    section: 1,
    persistentID: "customURLScheme",
    url: nil,
    invocation: .urlTemplate(
      Defaults.shared.editorCustomURL),
    name: "Custom URL Scheme"
  )

  static let otherApplication = Editor(
    section: 1,
    persistentID: "otherApplication",
    url: Defaults.shared.editorOtherApplication,
    invocation: .open,
    name: Defaults.shared
        .editorOtherApplication.map { url in
          LocalizedStringResource(
            String.LocalizationValue(url.displayName))
        } ?? "Other Application…"
  )

  let section: Int
  nonisolated let persistentID: String
  private let _url: () -> URL?
  var url: URL? { _url() }
  private let _invocation: () -> InvocationStyle
  var invocation: InvocationStyle { _invocation() }
  private let _name: () -> LocalizedStringResource
  var name: LocalizedStringResource { _name() }
  let scriptBundleName: String?
  let defaultScriptDestination: URL?
  let postInstall: (@MainActor () -> Void)?

  init(
    section: Int,
    persistentID: String,
    url: @escaping @autoclosure () -> URL?,
    invocation: @escaping @autoclosure () -> InvocationStyle,
    name: @escaping @autoclosure () -> LocalizedStringResource,
    scriptBundleName: String? = nil,
    defaultScriptDestination: URL? = nil,
    postInstall: (@MainActor () -> Void)? = nil
  ) {
    self.section = section
    self.persistentID = persistentID
    self._url = url
    self._invocation = invocation
    self._name = name
    self.scriptBundleName = scriptBundleName
    self.defaultScriptDestination = defaultScriptDestination
    self.postInstall = postInstall
  }

  init?(
    bundleIdentifiers: [String],
    invocation: InvocationStyle,
    scriptBundleName: String? = nil,
    defaultScriptDestination: URL? = nil,
    postInstall: (@MainActor () -> Void)? = nil)
  {
    guard
      let id = bundleIdentifiers.first,
      let url = bundleURL(bundleIdentifiers)
    else {
      return nil
    }
    self.init(
      section: 0,
      persistentID: id,
      url: url,
      invocation: invocation,
      name: LocalizedStringResource(
        String.LocalizationValue(url.displayName)),
      scriptBundleName: scriptBundleName,
      defaultScriptDestination: defaultScriptDestination,
      postInstall: postInstall
    )
  }

  /// Walks up `defaultScriptDestination` until it finds a directory
  /// that exists on disk. `NSOpenPanel` and SwiftUI's
  /// `fileDialogDefaultDirectory` both silently ignore non-existent
  /// URLs, so without this we'd drop back to the home folder
  /// instead of landing on the deepest ancestor that does exist.
  /// Falls back to `applicationSupportDirectory` for editors without
  /// a kit so callers always get a usable URL.
  var scriptPickerDefaultDirectory: URL {
    guard let destination = defaultScriptDestination else {
      return URL.applicationSupportDirectory
    }
    var current = destination
    while !current.itemExists {
      let parent = current.parent
      if parent == current { break }
      current = parent
    }
    return current
  }

  /// Per-editor token so the picker remembers each editor's
  /// last-used destination separately. Without it, picking a folder
  /// for BBEdit would replace Xcode's remembered default and vice
  /// versa.
  var scriptPickerCustomizationID: String {
    "is-\(persistentID)"
  }

  /// Copies this editor's bundled scripts folder into `destination`.
  /// Files at the destination with the same relative path are
  /// overwritten. Shell scripts get +x. Throws `.sourceMissing` if
  /// this editor has no kit or the bundle is absent from the app.
  ///
  /// Shell scripts in the bundle resolve the server endpoint at run
  /// time via `defaults read net.leuski.galley serverHTTPPort`, so
  /// the install is a plain copy — no port-placeholder rewriting.
  func installScripts(to destination: URL) throws {
    guard let bundleName = scriptBundleName,
          let source = Bundle.main.url(
            forResource: bundleName, withExtension: "bundle"),
          source.itemExists else {
      throw ScriptInstallError.sourceMissing
    }

    try destination.createDirectory()

    let walker = source.enumerator(
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles, .producesRelativePathURLs])

    for url in walker {
      let target = destination.appending(path: url.relativePath)

      do {
        try installScriptFile(from: url, to: target)
      } catch {
        throw ScriptInstallError.copyFailed(url, error)
      }
    }
  }

  private func installScriptFile(
    from source: URL, to target: URL
  ) throws {
    try target.parent.createDirectory()
    try source.copy(to: target, overwrite: true)
    if isShellScript(source) {
      try target.setPosixPermissions(0o755)
    }
  }

  private func isShellScript(_ url: URL) -> Bool {
    ["sh", "bash", "zsh", "command"]
      .contains(url.pathExtension.lowercased())
  }

  /// Post-install UI follow-up. Always reveals `destination` in
  /// Finder so the user can see where the scripts went; for editors
  /// whose script host needs poking (Xcode's system Script Menu),
  /// also enables and opens that host. Safe to call after every
  /// install — both the defaults write and the Script Menu launch
  /// are idempotent.
  @MainActor
  func presentInstalledScripts(at destination: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([destination])
    postInstall?()
  }

  func openFileInEditor(_ fileURL: URL, line: Int? = nil) async {
    switch invocation {
    case .urlTemplate(let template):
      openURL(template: template, fileURL: fileURL, line: line)
    case .command(let executable, let args):
      await runEditorCommand(
        executable: executable, args: args, fileURL: fileURL, line: line)
    case .open:
      await openURL(url: url, fileURL: fileURL, line: line)
    }
  }
}

private func openURL(url: URL?, fileURL: URL, line: Int?) async
{
  guard let url else {
    logger.warning("openFileInEditor: appBundle URL is nil")
    return
  }
  let configuration = NSWorkspace.OpenConfiguration()
  do {
    _ = try await NSWorkspace.shared.open(
      [fileURL], withApplicationAt: url,
      configuration: configuration)
  } catch {
    logger.error("""
      Failed to open \(fileURL.path, privacy: .public) in \
      \(url.path, privacy: .public): \
      \(error.localizedDescription, privacy: .public)
      """)
  }
}

private func openURL(template: String, fileURL: URL, line: Int?)
{
  let allowed = CharacterSet.urlQueryAllowed
    .subtracting(CharacterSet(charactersIn: "&=+?#"))
  let urlString = template.substituting(substitutions: [
    "{url}": fileURL.absoluteString
      .addingPercentEncoding(withAllowedCharacters: allowed)
    ?? fileURL.absoluteString,
    "{path}": fileURL.path.percentEncodedForPath,
    "{line}": line.map(String.init) ?? ""
  ])
  guard let url = URL(string: urlString) else {
    logger.error("""
          Editor URL is not a valid URL: \(urlString, privacy: .public)
          """)
    return
  }
  if !NSWorkspace.shared.open(url) {
    logger.error("""
          No handler accepted editor URL: \(urlString, privacy: .public)
          """)
  }
}

private func runEditorCommand(
  executable: String, args: [String],
  fileURL: URL, line: Int?
) async {
  let args = args.map { arg in arg.substituting(substitutions: [
    "{path}": fileURL.path,
    "{line}": line.map(String.init) ?? "1"
  ])}

  let executableURL = URL(filePath: executable)
  guard executableURL.isExecutable else {
    logger.error("""
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
      logger.error("""
        Editor command exited \(result.terminationStatus): \
        \(executable, privacy: .public) for \
        \(fileURL.path, privacy: .public): \
        \(result.error, privacy: .public)
        """)
    }
  } catch {
    logger.error("""
      Failed to launch editor command \(executable, privacy: .public) \
      for \(fileURL.path, privacy: .public): \
      \(error.localizedDescription, privacy: .public)
      """)
  }
}

@Observable
@MainActor
final class EditorStore {
  static let shared = EditorStore()

  var editors = {
    [
      Editor(
        bundleIdentifiers: ["com.barebones.bbedit"],
        invocation: .urlTemplate("x-bbedit://open?url={url}&line={line}"),
        scriptBundleName: "BBEditScripts",
        defaultScriptDestination: URL
          .applicationSupportDirectory/"BBEdit"/"Scripts"),
      Editor(
        bundleIdentifiers: ["com.macromates.TextMate"],
        invocation: .urlTemplate("txmt://open?url={url}&line={line}")),
      Editor(
        bundleIdentifiers: ["com.microsoft.VSCode"],
        invocation: .urlTemplate("vscode://file{path}:{line}")),
      Editor(
        bundleIdentifiers: ["com.sublimetext.4",
                            "com.sublimetext.3",
                            "com.sublimetext.2"],
        invocation: .urlTemplate("subl://open?url={url}&line={line}")),
      Editor(
        bundleIdentifiers: ["dev.zed.Zed"],
        invocation: .urlTemplate("zed://file{path}:{line}")),
      Editor(
        bundleIdentifiers: ["com.apple.dt.Xcode"],
        invocation: .command(
          executable: "/usr/bin/xed",
          args: ["--line", "{line}", "{path}"]),
        scriptBundleName: "XCodeScripts",
        defaultScriptDestination: URL
          .homeDirectory/"Library"/"Scripts"/"Applications"/"Xcode",
        postInstall: {
          // System Script Menu surfaces user scripts only when it's
          // enabled. Same as `defaults write com.apple.scriptmenu
          // ScriptMenuEnabled -bool true` — writing through
          // `UserDefaults(suiteName:)` skips a `Process` round-trip.
          UserDefaults(suiteName: "com.apple.scriptmenu")?
            .set(true, forKey: "ScriptMenuEnabled")
          NSWorkspace.shared.open(URL(
            filePath: "/System/Library/CoreServices/Script Menu.app"))
        }),
      .customURLScheme,
      .otherApplication
    ].compactMap { $0 }
  }()
}

extension Editor: RestorableChoiceValue {
  func isResident(in source: EditorStore) -> Bool {
    source.editors.contains { $0.persistentID == persistentID }
  }

  static func decode(
    _ persistent: PersistentRepresentation,
    from source: EditorStore) throws -> Editor
  {
    guard let value = source.editors.first(
      where: { $0.persistentID == persistent.id })
    else {
      throw AnyChoiceValueDecodingError.missingValue(persistent.name)
    }
    return value
  }

  static func values(from source: EditorStore) -> [Editor] {
    source.editors.map { $0 }
  }

  static func defaultElement(from source: EditorStore) -> Editor {
    source.editors.first ?? .customURLScheme
  }

  typealias Source = EditorStore

  func persist() -> NamedValue<String>? {
    NamedValue(
      id: persistentID,
      name: String(localized: name))
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.persistentID == rhs.persistentID
  }

  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(persistentID)
  }
}

typealias EditorChoice = Choice<Editor>

#endif
