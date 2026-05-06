import Foundation
import ALFoundation

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

  static var bundledSourceURL: URL? {
    Bundle.main.url(forResource: "Scripts", withExtension: nil)
  }

  /// `~/Library/Application Support/BBEdit/Scripts`. Used to seed the
  /// folder picker so the user lands on BBEdit's scripts directory by
  /// default. The path may not exist yet — callers should pair it
  /// with `nearestExistingDirectory(for:)` for the file dialog.
  public static var defaultBBEditDestination: URL {
    URL.applicationSupportDirectory/"BBEdit"/"Scripts"
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

  /// Copies the bundled Scripts folder into `destination`, customizing the
  /// hardcoded loopback port in shell scripts to match the running server.
  /// Files at the destination with the same relative path are overwritten.
  public static func install(
    to destination: URL, context: KeyValuePairs<String, String>) throws
  {
    guard let source = bundledSourceURL, source.itemExists else {
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
