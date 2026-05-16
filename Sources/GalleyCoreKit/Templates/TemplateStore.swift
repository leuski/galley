import Foundation
import Observation
import ALFoundation
#if os(macOS)
import AppKit
#endif

@Observable
@MainActor
public final class TemplateStore {
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
  public static let shared = TemplateStore(
    directoryURLs: [
      .bundleTemplatesDirectoryURL,
      GalleyConstants.applicationSupportDirectory / "Templates"
    ],
    watchedSourceIndices: [TemplateStore.userSourceIndex])

  /// Source index of the kit's bundled templates. Stable contract —
  /// the bundled `Default` template's ID prefix derives from this.
  /// `nonisolated` so the `Template.bundledDefault` static (which has
  /// no actor context) can use it without hopping main.
  public nonisolated static let bundleSourceIndex: Int = 0
  /// Source index of the user-installed templates folder for the
  /// production singleton. Tests may use any indexing they want.
  public nonisolated static let userSourceIndex: Int = 1

  public private(set) var templates: [Template] = []

  /// Ordered list of source directories. Index in this array is the
  /// source's `sourceIndex` and ends up as the prefix of every
  /// resulting template's `id`.
  @ObservationIgnored public let directoryURLs: [URL]
  @ObservationIgnored private let watchedSourceIndices: Set<Int>
  @ObservationIgnored private var watcherTasks: [Task<Void, Never>] = []

  /// The directory the user is expected to drop their own templates
  /// into. By convention this is the last entry in `directoryURLs`
  /// (the production singleton has user-installed at index 1, after
  /// the bundle at index 0). Used by `revealFolder()` and by Settings
  /// UI that links to "Open Templates Folder".
  public var userDirectoryURL: URL {
    directoryURLs.last ?? directoryURLs[0]
  }

  /// Fires after every `reload()` completes (initial + watcher-driven).
  /// `ProcessorStore.discover()` is awaited directly, but template
  /// reloads happen inside the file-system watcher, so callers that
  /// need to react (e.g. to run reconciliation) hook in here.
  @ObservationIgnored public var onReload: (@MainActor () -> Void)?

  public init(
    directoryURLs: [URL],
    watchedSourceIndices: Set<Int> = []
  ) {
    self.directoryURLs = directoryURLs
    self.watchedSourceIndices = watchedSourceIndices

    // Non-fatal: bundled templates still work if user dir creation fails.
    for index in watchedSourceIndices
    where directoryURLs.indices.contains(index) {
      try? directoryURLs[index].createDirectory()
    }

    reload()
    startWatching()
  }

  public func existingTemplate(forID id: String?) -> Template? {
    guard let id else { return nil }
    return templates.first { $0.id == id }
  }

  public func revealFolder() {
    #if os(macOS)
    NSWorkspace.shared.activateFileViewerSelecting([userDirectoryURL])
    #endif
  }

  public func reload() {
    let manager = FileManager.default
    var discovered: [Template] = []

    for (index, dir) in directoryURLs.enumerated() {
      let listingDir = dir.safe
      let contents = (try? manager.contentsOfDirectory(
        at: listingDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []

      let nameResourceProvider = makeNameResourceProvider(forSource: index)
      let entries: [Template] = contents.compactMap { url in
        Template(
          entryURL: url,
          sourceIndex: index,
          nameResource: nameResourceProvider(url.lastPathComponent))
      }
      discovered.append(contentsOf: entries)
    }

    let sorted = discovered.sorted {
      // Group by source first (so bundled appear before user), then
      // by display name within the source.
      if $0.sourceIndex != $1.sourceIndex {
        return $0.sourceIndex < $1.sourceIndex
      }
      return String(localized: $0.name)
        .localizedCaseInsensitiveCompare(
          String(localized: $1.name)) == .orderedAscending
    }

    if sorted.map(\.id) != templates.map(\.id) {
      templates = sorted
    }
    onReload?()
  }

  /// Literal `LocalizedStringResource`s for every bundled template so
  /// Xcode's catalog extraction picks the labels up. Keyed by the
  /// template's on-disk base name (`Default.html` → `"Default"`,
  /// `Tufte/` → `"Tufte"`). Add a row when adding a new bundled
  /// template; the rest of the discovery path is filename-driven.
  private static let bundledNameResources:
    [String: LocalizedStringResource] = [
    "Default": LocalizedStringResource(
      "Default", bundle: .galleyCoreKit),
    "GitHub": LocalizedStringResource(
      "GitHub", bundle: .galleyCoreKit),
    "HighContrast": LocalizedStringResource(
      "High Contrast", bundle: .galleyCoreKit),
    "LaTeX": LocalizedStringResource(
      "LaTeX", bundle: .galleyCoreKit),
    "Manuscript": LocalizedStringResource(
      "Manuscript", bundle: .galleyCoreKit),
    "Sepia": LocalizedStringResource(
      "Sepia", bundle: .galleyCoreKit),
    "Solarized": LocalizedStringResource(
      "Solarized", bundle: .galleyCoreKit),
    "Terminal": LocalizedStringResource(
      "Terminal", bundle: .galleyCoreKit),
    "Tufte": LocalizedStringResource(
      "Tufte", bundle: .galleyCoreKit)
  ]

  /// For the bundled source, look the translatable label up in
  /// `bundledNameResources`. User-source templates fall back to the
  /// runtime `LocalizationValue` derived from the filename.
  private func makeNameResourceProvider(
    forSource index: Int
  ) -> (String) -> LocalizedStringResource? {
    guard index == Self.bundleSourceIndex else { return { _ in nil } }
    return { entryName in
      // Strip `.html` / `.htm` so file-shape bundled templates and
      // folder-shape bundled templates resolve to the same key.
      let url = URL(fileURLWithPath: entryName)
      let ext = url.pathExtension.lowercased()
      let base = (ext == "html" || ext == "htm")
        ? url.deletingPathExtension().lastPathComponent
        : entryName
      return Self.bundledNameResources[base]
    }
  }

  private func startWatching() {
    #if os(macOS)
    for index in watchedSourceIndices {
      guard directoryURLs.indices.contains(index) else { continue }
      let url = directoryURLs[index]
      let task = Task { [weak self] in
        let events = url.fileEvents(eventMask: .all)
          .debounce(for: .milliseconds(150))
        for await _ in events {
          self?.reload()
        }
      }
      watcherTasks.append(task)
    }
    #endif
  }
}
