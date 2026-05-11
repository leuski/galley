import AppKit
import GalleyCoreKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Wraps `NSDocumentController.shared.recentDocumentURLs` and the
/// File > Open / Open Recent flows.
///
/// Why a separate model? Two reasons:
///   - SwiftUI's `WindowGroup` doesn't auto-populate File >
///     Open Recent (that menu is wired to `NSDocumentController` in
///     `DocumentGroup`-based apps). We surface the list ourselves
///     and rebuild the SwiftUI menu from it.
///   - File > Open runs an `NSOpenPanel`. Hosting the panel here
///     instead of inside `ViewerAppDelegate` removes that hook from
///     the AppDelegate's responsibility surface.
///
/// Constructed once by `ViewerApp` and injected via `.environment()`.
@MainActor
@Observable
final class RecentDocumentsModel {
  /// Mirrors `NSDocumentController.shared.recentDocumentURLs`.
  /// Bound from the File menu's Open Recent submenu.
  private(set) var urls: [URL] = []

  /// Active FTUE open panel, kept weak so we don't extend its
  /// lifetime past presentation.
  @ObservationIgnored private weak var activeOpenPanel: NSOpenPanel?

  /// Routes opened URLs through the same pipeline as Finder
  /// dispatches. Wired by `ViewerApp.body` after construction.
  @ObservationIgnored weak var dispatcher: WindowDispatcher?

  init() {
    self.urls = NSDocumentController.shared.recentDocumentURLs
  }

  /// Record a URL as recently opened.
  func record(_ url: URL) {
    guard !url.safe.path.hasPrefix(Bundle.main.bundleURL.safe.path)
    else { return }
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
    urls = NSDocumentController.shared.recentDocumentURLs
  }

  /// Clear the recents list. Called from File > Open Recent >
  /// Clear Menu.
  func clearAll() {
    NSDocumentController.shared.clearRecentDocuments(nil)
    urls = NSDocumentController.shared.recentDocumentURLs
  }

  /// Open one previously-opened URL through the same dispatch path
  /// as Finder/NSOpenPanel — used by the Open Recent menu.
  func openRecent(_ url: URL) {
    dispatcher?.handleOpenURLs([url])
    record(url)
  }

  /// Run NSOpenPanel and route picks through the dispatcher. The
  /// File menu wires its Open command directly to this.
  func presentOpenPanel() {
    Task {
      let picks = await runOpenPanel()
      for url in picks { record(url) }
      dispatcher?.handleOpenURLs(picks)
    }
  }

  /// Run NSOpenPanel and return the picks without dispatching.
  /// Used by the welcome FTUE flow so the caller can route them.
  ///
  /// Uses the async `begin` form rather than `runModal` because
  /// `runModal` cannot start inside a SwiftUI/CoreAnimation
  /// transaction commit.
  func runOpenPanel() async -> [URL] {
    let panel = NSOpenPanel()
    panel.identifier = .init(rawValue: "open.file.panel")
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = Self.openPanelContentTypes
    activeOpenPanel = panel
    let response: NSApplication.ModalResponse =
    await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    if activeOpenPanel === panel { activeOpenPanel = nil }
    guard response == .OK else { return [] }
    return panel.urls
  }

  private static let openPanelContentTypes: [UTType] = {
    var types: [UTType] = []
    types.append(UTType(importedAs: "net.daringfireball.markdown"))
    for ext in MarkdownFileTypes.extensions {
      if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    types.append(.plainText)
    return types
  }()
}
