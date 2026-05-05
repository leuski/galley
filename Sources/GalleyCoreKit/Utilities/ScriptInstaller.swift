import Foundation
import ALFoundation
import SwiftUI

public enum ScriptInstaller {
  enum InstallError: LocalizedError {
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

  static var bundledSourceURL: URL? {
    Bundle.main.url(forResource: "Scripts", withExtension: nil)
  }

  static var defaultBBEditDestination: URL {
    URL.applicationSupportDirectory/"BBEdit"/"Scripts"
  }

  /// Copies the bundled Scripts folder into `destination`, customizing the
  /// hardcoded loopback port in shell scripts to match the running server.
  /// Files at the destination with the same relative path are overwritten.
  static func install(
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

  @MainActor
  static public func installScripts(
    context: KeyValuePairs<String, String> = [:])
  {
    let panel = NSOpenPanel()
    panel.identifier = .init(rawValue: "install-scripts")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Install"
    panel.title = "Install BBEdit Scripts"
    panel.message = """
      Choose the destination folder. Defaults to BBEdit's Scripts folder.
      """

    let defaultDestination = ScriptInstaller.defaultBBEditDestination
    panel.directoryURL = nearestExistingDirectory(for: defaultDestination)

    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    do {
      try ScriptInstaller.install(to: destination, context: context)
      NSWorkspace.shared.activateFileViewerSelecting([destination])
    } catch {
      let alert = NSAlert(error: error)
      alert.messageText = "Could not install scripts"
      alert.runModal()
    }
  }

  private static func nearestExistingDirectory(for url: URL) -> URL {
    var current = url
    while !current.itemExists {
      let parent = current.parent
      if parent == current { break }
      current = parent
    }
    return current
  }
}
