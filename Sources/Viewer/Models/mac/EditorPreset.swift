#if os(macOS)
import AppKit
import Foundation
import GalleyCoreKit

/// A built-in editor whose URL scheme + line-jump format we know.
/// Also owns its bundled-scripts kit (BBEdit/Xcode) — name of the
/// resource bundle, default install destination, and the install
/// routine that copies the bundle out to a user-chosen folder.
enum EditorPreset: String, Codable, CaseIterable, Identifiable,
                   Hashable, Sendable
{
  case bbedit
  case textmate
  case vscode
  case sublime
  case zed
  case xcode

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .bbedit:   "BBEdit"
    case .textmate: "TextMate"
    case .vscode:   "Visual Studio Code"
    case .sublime:  "Sublime Text"
    case .zed:      "Zed"
    case .xcode:    "Xcode"
    }
  }

  /// How this editor accepts a "open file at line" request. URL-template
  /// editors register a custom URL scheme we hand to `NSWorkspace`; the
  /// command form launches a CLI tool because the editor either has no
  /// URL scheme (Xcode) or only a partial one.
  enum InvocationStyle: Sendable, Hashable {
    /// `{url}`, `{path}`, `{line}` placeholders, percent-encoded for
    /// their position in the URL.
    case urlTemplate(String)
    /// Executable + argument list. `{path}` and `{line}` placeholders
    /// in `args` substitute raw (no URL encoding); `{line}` substitutes
    /// to `1` when the caller passes nil.
    case command(executable: String, args: [String])
  }

  var invocation: InvocationStyle {
    switch self {
    case .bbedit:
      .urlTemplate("x-bbedit://open?url={url}&line={line}")
    case .textmate:
      .urlTemplate("txmt://open?url={url}&line={line}")
    case .vscode:
      .urlTemplate("vscode://file{path}:{line}")
    case .sublime:
      .urlTemplate("subl://open?url={url}&line={line}")
    case .zed:
      .urlTemplate("zed://file{path}:{line}")
    case .xcode:
      .command(
        executable: "/usr/bin/xed",
        args: ["--line", "{line}", "{path}"])
    }
  }

  /// URL template if the preset uses one; `nil` for command-style
  /// presets. Used to seed the `customURL` slot from a known-good
  /// example template.
  var urlTemplate: String? {
    if case .urlTemplate(let template) = invocation { return template }
    return nil
  }

  /// Subset of `allCases` that use a URL-template invocation. Tests
  /// that exercise URL substitution iterate this; command-style
  /// presets get their own coverage.
  static var urlTemplatePresets: [EditorPreset] {
    allCases.filter { $0.urlTemplate != nil }
  }

  /// Subset of `allCases` that launch a CLI tool.
  static var commandPresets: [EditorPreset] {
    allCases.filter {
      if case .command = $0.invocation { return true }
      return false
    }
  }

  // MARK: - Bundled scripts

  /// Resource name of the `.bundle` folder in `Bundle.main` (without
  /// the `.bundle` extension). Editors without a kit return nil and
  /// the settings UI hides the install affordance for them. The
  /// bundle is shipped as a folder reference and its `.applescript`
  /// sources are compiled to `.scpt` at build time (see
  /// `Scripts/compile-applescripts.sh`).
  var scriptBundleName: String? {
    switch self {
    case .bbedit: "BBEditScripts"
    case .xcode:  "XCodeScripts"
    case .textmate, .vscode, .sublime, .zed: nil
    }
  }

  /// Default install destination shown to the user in the folder
  /// picker. Nil if this editor doesn't ship scripts. May not exist
  /// on disk yet — see `scriptPickerDefaultDirectory` for the
  /// walked-up version safe to hand to the picker.
  var defaultScriptDestination: URL? {
    switch self {
    // `~/Library/Application Support/BBEdit/Scripts` — BBEdit's user
    // scripts directory.
    case .bbedit:
      URL.applicationSupportDirectory/"BBEdit"/"Scripts"
    // `~/Library/Scripts/Applications/Xcode` — macOS Script Menu
    // per-application directory. Scripts placed here surface in the
    // system Script Menu only when Xcode is frontmost.
    case .xcode:
      URL.homeDirectory/"Library"/"Scripts"/"Applications"/"Xcode"
    case .textmate, .vscode, .sublime, .zed:
      nil
    }
  }

  /// True if this editor ships bundled scripts. Drives the
  /// "Install scripts…" affordance in Settings.
  var hasScriptKit: Bool { scriptBundleName != nil }

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
    "is-\(scriptBundleName ?? "default")"
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
    switch self {
    case .xcode:
      // System Script Menu surfaces user scripts only when it's
      // enabled. Same as `defaults write com.apple.scriptmenu
      // ScriptMenuEnabled -bool true` — writing through
      // `UserDefaults(suiteName:)` skips a `Process` round-trip.
      UserDefaults(suiteName: "com.apple.scriptmenu")?
        .set(true, forKey: "ScriptMenuEnabled")
      NSWorkspace.shared.open(URL(filePath:
        "/System/Library/CoreServices/Script Menu.app"))
    case .bbedit, .textmate, .vscode, .sublime, .zed:
      break
    }
  }
}

#endif
