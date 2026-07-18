import Foundation
import Observation
import OSLog
#if os(macOS)
import AppKit
#endif

private let log = Logger(
  subsystem: bundleIdentifier, category: "TemplateStore")

public struct TemplateStorePolicy: FolderBasedStorePolicy<Template> {

  /// Source index of the kit's bundled templates. Stable contract —
  /// the bundled `Default` template's ID prefix derives from this.
  /// `nonisolated` so the `Template.bundledDefault` static (which has
  /// no actor context) can use it without hopping main.
  nonisolated static let bundleSourceIndex: Int = 0
  /// Source index of the user-installed templates folder for the
  /// production singleton. Tests may use any indexing they want.
  nonisolated static let userSourceIndex: Int = 1

  private static func nameResource(
    for url: URL, at index: Int) -> String?
  {
    guard index == bundleSourceIndex else { return nil }
    let ext = url.pathExtension.lowercased()
    let base = (ext == "html" || ext == "htm")
    ? url.deletingPathExtension().lastPathComponent
    : url.lastPathComponent
    return bundledNameResources[base]
  }

  public static func load(from url: URL, sourceIndex: Int) throws -> Template? {
    Template(
      entryURL: url,
      sourceIndex: sourceIndex,
      nameResource: nameResource(for: url, at: sourceIndex))
  }

  public static let defaultValue: Template = .bundledDefault

  /// Literal `LocalizedStringResource`s for every bundled template so
  /// Xcode's catalog extraction picks the labels up. Keyed by the
  /// template's on-disk base name (`Default.html` → `"Default"`,
  /// `Tufte/` → `"Tufte"`). Add a row when adding a new bundled
  /// template; the rest of the discovery path is filename-driven.
  private static let bundledNameResources:
  [String: String] = [
    "Default": "Default",
    "GitHub": "GitHub",
    "HighContrast": "High Contrast",
    "LaTeX": "LaTeX",
    "Manuscript": "Manuscript",
    "Sepia": "Sepia",
    "Solarized": "Solarized",
    "Terminal": "Terminal",
    "Tufte": "Tufte"
  ].mapValues { value in String(localized: value, bundle: .galleyCoreKit) }
}

public typealias TemplateStore = FolderBasedStore<TemplateStorePolicy>

public extension TemplateStore {
  /// Process-wide singleton. Two sources by default:
  /// - **Index 0**: the kit's bundled `Templates/` directory (read-only,
  ///   contains the `Default` template).
  /// - **Index 1**: `~/Library/Application Support/<suite>/Templates/`,
  ///   where users drop their own templates. Watched for filesystem
  ///   events.
  ///
  /// IDs are stamped `<index>.<name>` so a user template named
  /// "Default" coexists with the bundled "Default" without collision.
  /// Tests should construct their own instances via `init(directoryURLs:)`
  /// against tmp dirs and seed whatever entries they need.
  static let shared = TemplateStore(
    directoryURLs: [
      .bundleTemplatesDirectoryURL,
      GalleyConstants.applicationSupportDirectory / "Templates"
    ],
    watchedSourceIndices: [TemplateStorePolicy.userSourceIndex])
}

public extension Template {
  /// Fallback for callers that need a known-good template without a
  /// store handy (e.g. the Server's renderer-provider closure when
  /// the template choice has been GC'd). Resolves the bundled
  /// "Default" entry directly off the kit's bundle resources.
  static let bundledDefault: Template = {
    guard let template = Template(
      sourceURL: .bundleTemplatesDirectoryURL,
      sourceIndex: TemplateStorePolicy.bundleSourceIndex,
      name: "Default.html",
      nameResource: String(localized: "Default", bundle: .galleyCoreKit))
    else {
      fatalError("GalleyCoreKit bundle missing Templates.bundle/Default.html")
    }
    return template
  }()
}
