import Foundation
import ALFoundation

/// Per-editor description of where a bundled scripts folder lives in the
/// product and where the user normally installs it on disk. Editors that
/// don't ship scripts have no kit; the settings UI hides the install
/// affordance for them.
public struct EditorScriptKit: Sendable, Hashable {
  /// Resource name of the `.bundle` folder in `Bundle.main` (without the
  /// `.bundle` extension). The bundle is shipped as a folder reference and
  /// its `.applescript` sources are compiled to `.scpt` at build time
  /// (see `Scripts/compile-applescripts.sh`).
  public let bundleName: String

  /// Default install destination shown to the user in the folder picker.
  /// May not exist yet — pair with `ScriptInstaller.nearestExistingDirectory`
  /// before handing to `NSOpenPanel` / `.fileDialogDefaultDirectory`.
  public let defaultDestination: URL

  public init(bundleName: String, defaultDestination: URL) {
    self.bundleName = bundleName
    self.defaultDestination = defaultDestination
  }

  /// `~/Library/Application Support/BBEdit/Scripts` — BBEdit's user
  /// scripts directory.
  public static let bbedit = EditorScriptKit(
    bundleName: "BBEditScripts",
    defaultDestination:
      URL.applicationSupportDirectory/"BBEdit"/"Scripts")

  /// `~/Library/Scripts/Applications/Xcode` — macOS Script Menu
  /// per-application directory. Scripts placed here surface in the
  /// system Script Menu only when Xcode is frontmost.
  public static let xcode = EditorScriptKit(
    bundleName: "XCodeScripts",
    defaultDestination:
      URL.homeDirectory/"Library"/"Scripts"/"Applications"/"Xcode")
}

public enum ScriptInstaller {
  public enum InstallError: LocalizedError {
    case sourceMissing
    case copyFailed(URL, any Error)

    public var errorDescription: String? {
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

  /// Walks up `url` until it finds a directory that exists on disk.
  /// `NSOpenPanel` and SwiftUI's `fileDialogDefaultDirectory` both
  /// silently ignore non-existent URLs, so we land on the deepest
  /// ancestor that does exist instead of dropping back to the home
  /// folder.
  public static func nearestExistingDirectory(for url: URL) -> URL {
    var current = url
    while !current.itemExists {
      let parent = current.parent
      if parent == current { break }
      current = parent
    }
    return current
  }

  /// Copies `kit.bundleName.bundle` from the main bundle into
  /// `destination`, customizing the hardcoded loopback port in shell
  /// scripts to match the running server. Files at the destination with
  /// the same relative path are overwritten.
  public static func install(
    _ kit: EditorScriptKit,
    to destination: URL,
    context: KeyValuePairs<String, String>
  ) throws {
    guard let source = Bundle.main.url(
      forResource: kit.bundleName, withExtension: "bundle"),
      source.itemExists else {
      throw InstallError.sourceMissing
    }

    try destination.createDirectory()

    let walker = source.enumerator(
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles, .producesRelativePathURLs])

    for url in walker {
      let target = destination.appending(path: url.relativePath)

      do {
        try installFile(from: url, to: target, context: context)
      } catch {
        throw InstallError.copyFailed(url, error)
      }
    }
  }

  private static func installFile(
    from source: URL, to target: URL, context: KeyValuePairs<String, String>
  ) throws {
    try target.parent.createDirectory()

    if isShellScript(source) {
      let original = try String(contentsOf: source, encoding: .utf8)
      let customized = original.substituting(substitutions: context)
      try? target.remove()
      try customized.write(to: target, atomically: true, encoding: .utf8)
      try target.setPosixPermissions(0o755)
    } else {
      try source.copy(to: target, overwrite: true)
    }
  }

  private static func isShellScript(_ url: URL) -> Bool {
    ["sh", "bash", "zsh", "command"].contains(url.pathExtension.lowercased())
  }

}
