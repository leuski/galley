import Foundation
import Observation
import ALFoundation
import AppKit

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
      TemplateStore.bundleTemplatesDirectoryURL,
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
    NSWorkspace.shared.activateFileViewerSelecting([userDirectoryURL])
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

  /// For the bundled source, supply literal `LocalizedStringResource`s
  /// so Xcode's catalog extraction picks up the translatable labels.
  /// User-source templates fall back to the runtime
  /// `LocalizationValue` derived from the filename.
  private func makeNameResourceProvider(
    forSource index: Int
  ) -> (String) -> LocalizedStringResource? {
    guard index == Self.bundleSourceIndex else { return { _ in nil } }
    return { entryName in
      // Strip `.html` / `.htm` so file-shape bundled templates and
      // folder-shape bundled templates resolve to the same key.
      let base: String = {
        let url = URL(fileURLWithPath: entryName)
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
          return url.deletingPathExtension().lastPathComponent
        }
        return entryName
      }()
      switch base {
      case "Default":
        return LocalizedStringResource(
          "Default", bundle: .galleyCoreKit)
      default:
        return nil
      }
    }
  }

  private func startWatching() {
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
  }

  /// Resolves the kit framework's bundled templates folder.
  ///
  /// The bundled templates ship inside a `Templates.bundle` directory
  /// because Xcode 16's synchronized root groups otherwise flatten
  /// resource directory structure when copying — a `.bundle`-suffixed
  /// folder is treated as an opaque wrapper and copied whole. Inside
  /// the wrapper we keep one folder per template (`Default/`,
  /// future `Tufte/`, etc.) using the same folder shape user
  /// templates use.
  nonisolated public static let bundleTemplatesDirectoryURL: URL = {
    guard
      let url = Bundle.galleyCoreKit.url(
        forResource: "Templates", withExtension: "bundle")
    else {
      fatalError("GalleyCoreKit bundle missing Templates.bundle wrapper")
    }
    return url
  }()
}
