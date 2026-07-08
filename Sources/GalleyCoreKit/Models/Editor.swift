//
//  Editor.swift
//  Galley
//
//  Created by Anton Leuski on 7/1/26.
//

#if os(macOS)
import AppKit
import Foundation
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

public enum InvocationStyle: Sendable, Hashable {
  public static let defaultCustomURL = "x-bbedit://open?url={url}&line={line}"

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

private let customURLSchemeID = "customURLScheme"
private let otherApplicationID = "otherApplication"

@MainActor
public struct Editor: SectionedChoiceValue, Identifiable, @MainActor Equatable
{
  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs.id, rhs.id) {
    case (customURLSchemeID, customURLSchemeID):
      lhs.invocation == rhs.invocation
    case (otherApplicationID, otherApplicationID):
      lhs.url == rhs.url
    default:
      lhs.id == rhs.id
    }
  }

  public static func customURLScheme<D>(_ defaults: D) -> Editor
  where D: GalleyEditorDefaults
  {
    Editor(
      section: 1,
      id: customURLSchemeID,
      url: nil,
      invocation: .urlTemplate(defaults.editorCustomURL),
      name: "Custom URL Scheme"
    )
  }

  public static func otherApplication<D>(_ defaults: D) -> Editor
  where D: GalleyEditorDefaults
  {
    Editor(
      section: 1,
      id: otherApplicationID,
      url: defaults.editorOtherApplication,
      invocation: .open,
      name: defaults
        .editorOtherApplication.map { url in
          LocalizedStringResource(
            String.LocalizationValue(url.displayName))
        } ?? "Other Application…"
    )
  }

  public let section: Int
  public nonisolated let id: String
  private let _url: () -> URL?
  public var url: URL? { _url() }
  private let _invocation: () -> InvocationStyle
  public var invocation: InvocationStyle { _invocation() }
  private let _name: () -> LocalizedStringResource
  public var name: LocalizedStringResource { _name() }
  public let scriptBundleName: String?
  public let defaultScriptDestination: URL?
  public let postInstall: (@MainActor () -> Void)?

  init(
    section: Int,
    id: String,
    url: @escaping @autoclosure () -> URL?,
    invocation: @escaping @autoclosure () -> InvocationStyle,
    name: @escaping @autoclosure () -> LocalizedStringResource,
    scriptBundleName: String? = nil,
    defaultScriptDestination: URL? = nil,
    postInstall: (@MainActor () -> Void)? = nil
  ) {
    self.section = section
    self.id = id
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
      id: id,
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
  public var scriptPickerDefaultDirectory: URL {
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
  public var scriptPickerCustomizationID: String {
    "is-\(id)"
  }

  /// Copies this editor's bundled scripts folder into `destination`.
  /// Files at the destination with the same relative path are
  /// overwritten. Shell scripts get +x. Throws `.sourceMissing` if
  /// this editor has no kit or the bundle is absent from the app.
  ///
  /// Shell scripts in the bundle resolve the server endpoint at run
  /// time via `defaults read net.leuski.galley serverHTTPPort`, so
  /// the install is a plain copy — no port-placeholder rewriting.
  public func installScripts(to destination: URL) throws {
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
  public func presentInstalledScripts(at destination: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([destination])
    postInstall?()
  }

  public func openFileInEditor(_ fileURL: URL, line: Int? = nil) async {
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

/// Substitutes the `{url}`, `{path}`, `{line}` placeholders in a
/// URL-scheme editor template. `{url}` is `absoluteString` re-encoded
/// for a query slot (so it survives as a query parameter), `{path}`
/// is the raw path percent-encoded for a path slot, and `{line}`
/// substitutes to the empty string when the caller passes nil.
/// Shared by the live open path and the unit tests.
func substituteEditorTemplate(
  _ template: String, fileURL: URL, line: Int?
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

/// Substitutes `{path}` and `{line}` in a single command argument
/// with no URL encoding. `{line}` falls back to `"1"` when the caller
/// passes nil so `--line {line}` always sees a valid integer. Shared
/// by the live open path and the unit tests.
func substituteCommandArg(
  _ arg: String, fileURL: URL, line: Int?
) -> String {
  arg.substituting(substitutions: [
    "{path}": fileURL.path,
    "{line}": line.map(String.init) ?? "1"
  ])
}

private func openURL(template: String, fileURL: URL, line: Int?)
{
  let urlString = substituteEditorTemplate(
    template, fileURL: fileURL, line: line)
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
  let args = args.map { arg in
    substituteCommandArg(arg, fileURL: fileURL, line: line)
  }

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
public final class EditorStore {
  public let editors: [Editor]
  public let customURLScheme: Editor
  public let otherApplication: Editor
  public let defaultEditor: Editor

  public init<D>(_ defaults: D)
  where D: GalleyEditorDefaults
  {
    self.otherApplication = .otherApplication(defaults)
    self.customURLScheme = .customURLScheme(defaults)
    self.defaultEditor = customURLScheme
    self.editors = [
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
        defaultEditor,
        otherApplication
      ].compactMap { $0 }
  }

  public func anyEditor(forID id: Editor.ID?) -> Editor {
    editors.first { $0.id == id } ?? defaultEditor
  }
}

public struct EditorPolicy: @MainActor SelectablePolicy<Editor> {
  public typealias PersistentSelectionRepresentation = NamedPair<Editor.ID>
  public typealias Selection = Editor

  private let store: EditorStore
  public var elements: [Element] { store.editors }
  public var defaultSelection: Selection {
    store.editors.first ?? store.defaultEditor }
  public func decode(_ value: PersistentSelectionRepresentation) -> Selection? {
    store.editors.first { $0.id == value.id }
  }
  public func encode(_ value: Selection) -> PersistentSelectionRepresentation {
    .init(id: value.id, name: String(localized: value.name))
  }
  public func contains(_ value: Selection) -> Bool {
    store.editors.first { $0.id == value.id } != nil
  }
  public init(_ store: EditorStore) {
    self.store = store
  }
  public init<D>(_ defaults: D)
  where D: GalleyEditorDefaults
  {
    self.init(EditorStore(defaults))
  }
}

public typealias EditorChoice = SelectableModel<EditorPolicy>

#endif
