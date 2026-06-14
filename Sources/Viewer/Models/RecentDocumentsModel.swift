#if os(macOS)
import AppKit
#endif
import GalleyCoreKit
import Observation
import SwiftUI
import KosmosAppKit

#if !os(macOS)
/// Persisted form of a visionOS recent entry. File URLs carry a
/// bookmark blob so we can re-resolve a fresh security-scoped URL
/// after relaunch; remote URLs (http(s), galley://, etc.) carry only
/// the URL — they don't need or support security-scoped bookmarks.
struct RecentDocumentEntry: Codable, Hashable, Sendable {
  let url: URL
  let bookmark: Data?
}
#endif

/// Recently-opened-document list surfaced by File > Open Recent (macOS)
/// and by the welcome screen + More > Open Recent menu (visionOS).
///
/// The two platforms back this very differently:
///
/// - **macOS** wraps `NSDocumentController.shared.recentDocumentURLs`.
///   That's the source of truth — the Dock's "Recent Documents"
///   menu, system-managed dedup + cap, and the on-disk plist are all
///   handled by AppKit. We just mirror the list and own the
///   `NSOpenPanel` flow.
///
/// - **visionOS** has no equivalent of `NSDocumentController`. File
///   URLs from the file importer are security-scoped grants that
///   can't be persisted as plain paths, so we persist a bookmark
///   alongside the URL and re-resolve at open time. Remote URLs need
///   no bookmark and round-trip as URL-only entries — both kinds
///   share one list, ordered most-recent-first.
///
/// Constructed once by the app's `@main` and injected via
/// `.environment()`.
@MainActor
@Observable
final class RecentDocumentsModel {
  /// URLs ordered most-recent-first. Bound by the menu /
  /// welcome-screen UI.
  private(set) var urls: [URL] = []

#if os(macOS)
  /// Active FTUE open panel, kept weak so we don't extend its
  /// lifetime past presentation.
  @ObservationIgnored private weak var activeOpenPanel: NSOpenPanel?
#else
  /// Cap matching the macOS system default. visionOS has no
  /// equivalent of System Settings → Desktop & Dock → Recent items.
  static let maxItems = 10

  /// Index-aligned with `urls`. Persisted to `Defaults.recentEntries`
  /// on every mutation.
  @ObservationIgnored private var entries: [RecentDocumentEntry] = []
#endif

  init() {
#if os(macOS)
    self.urls = NSDocumentController.shared.recentDocumentURLs
#else
    let stored = Defaults.shared.recentEntries
    let resolved = Self.resolve(entries: stored)
    self.entries = resolved
    self.urls = resolved.map(\.url)
    if resolved != stored {
      Defaults.shared.recentEntries = resolved
    }
#endif
  }

  /// Record a URL as recently opened.
  func record(_ url: URL) {
    guard !url.isInMainBundle else { return }
#if os(macOS)
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
    urls = NSDocumentController.shared.recentDocumentURLs
#else
    let bookmark: Data?
    if url.isFileURL {
      // The picker grants security scope on the URL we receive;
      // bookmarkData captures that grant so we can re-resolve a
      // fresh scoped URL after relaunch. If bookmark creation fails
      // (no scope, transient FS error), bail rather than persisting
      // a file URL we won't be able to reopen.
      guard let data = try? url.bookmarkData() else { return }
      bookmark = data
    } else {
      bookmark = nil
    }
    let entry = RecentDocumentEntry(url: url, bookmark: bookmark)
    let key = Self.dedupeKey(for: url)
    var newEntries: [RecentDocumentEntry] = [entry]
    for existing in entries
    where Self.dedupeKey(for: existing.url) != key {
      newEntries.append(existing)
    }
    if newEntries.count > Self.maxItems {
      newEntries = Array(newEntries.prefix(Self.maxItems))
    }
    entries = newEntries
    urls = newEntries.map(\.url)
    Defaults.shared.recentEntries = newEntries
#endif
  }

  /// Clear the recents list. Called from File > Open Recent >
  /// Clear Menu (macOS) and the Open Recent submenu footer
  /// (visionOS).
  func clearAll() {
#if os(macOS)
    NSDocumentController.shared.clearRecentDocuments(nil)
    urls = NSDocumentController.shared.recentDocumentURLs
#else
    urls = []
    entries = []
    Defaults.shared.recentEntries = []
#endif
  }

#if os(macOS)
  func resolveRecentURL(_ url: URL) -> URL? {
    url
  }

  /// Open one previously-opened URL through the same path as
  /// Finder/NSOpenPanel (fire-at-self) — used by the Open Recent menu.
  func openRecent(_ url: URL) {
    GalleyRequestActivity(url: url).open()
  }

  /// Run NSOpenPanel and route picks through the app's own URL handler
  /// (fire-at-self). The File menu wires its Open command to this.
  func presentOpenPanel() {
    Task {
      let picks = await runOpenPanel()
      for url in picks {
        GalleyRequestActivity(url: url).open()
      }
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
    panel.allowedContentTypes = MarkdownFileTypes.allTypesAndPlainText
    activeOpenPanel = panel
    let response: NSApplication.ModalResponse =
    await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    if activeOpenPanel === panel { activeOpenPanel = nil }
    guard response == .OK else { return [] }
    return panel.urls
  }
#else
  /// Resolve a recent entry and return a URL the caller can bind to
  /// its `WindowGroup` slot. For file entries that means re-resolving
  /// the bookmark and starting security-scoped access; for remote
  /// entries it's the stored URL as-is. Returns nil for a dead file
  /// entry (bookmark unresolvable) and prunes it as a side effect.
  ///
  /// Refreshes the on-disk bookmark when resolution reports stale
  /// data, and re-prepends the entry so reopening promotes it.
  func resolveRecentURL(_ url: URL) -> URL? {
    let key = Self.dedupeKey(for: url)
    guard let idx = entries.firstIndex(where: {
      Self.dedupeKey(for: $0.url) == key
    }) else { return nil }
    let entry = entries[idx]
    let resolved: URL
    let refreshedBookmark: Data?
    if let data = entry.bookmark {
      var stale = false
      let fresh = try? URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale)
      guard let fresh else {
        entries.remove(at: idx)
        urls.remove(at: idx)
        Defaults.shared.recentEntries = entries
        return nil
      }
      _ = fresh.startAccessingSecurityScopedResource()
      resolved = fresh
      if stale, let updated = try? fresh.bookmarkData() {
        refreshedBookmark = updated
      } else {
        refreshedBookmark = data
      }
    } else {
      resolved = entry.url
      refreshedBookmark = nil
    }
    let promoted = RecentDocumentEntry(
      url: resolved,
      bookmark: refreshedBookmark)
    var newEntries: [RecentDocumentEntry] = [promoted]
    for (offset, existing) in entries.enumerated() where offset != idx {
      newEntries.append(existing)
    }
    entries = newEntries
    urls = newEntries.map(\.url)
    Defaults.shared.recentEntries = newEntries
    return resolved
  }

  /// Drop one entry by its resolved URL. Surfaced from the
  /// welcome-screen context menu.
  func remove(_ url: URL) {
    let key = Self.dedupeKey(for: url)
    guard let idx = entries.firstIndex(where: {
      Self.dedupeKey(for: $0.url) == key
    }) else { return }
    entries.remove(at: idx)
    urls.remove(at: idx)
    Defaults.shared.recentEntries = entries
  }

  /// File URLs may resolve to differently-formed paths after
  /// re-resolution (`/private/var` vs `/var`, scoped vs not). Compare
  /// canonical FS paths there; remote URLs have no such concern and
  /// compare by absolute string.
  private static func dedupeKey(for url: URL) -> String {
    url.isFileURL ? url.safe.path : url.absoluteString
  }

  /// Resolve a stored list, dropping unresolvable file entries and
  /// refreshing stale bookmarks. Remote entries (no bookmark) pass
  /// through untouched.
  private static func resolve(
    entries stored: [RecentDocumentEntry]
  ) -> [RecentDocumentEntry] {
    var result: [RecentDocumentEntry] = []
    for entry in stored {
      guard let data = entry.bookmark else {
        result.append(entry)
        continue
      }
      var stale = false
      let resolved = try? URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale)
      guard let url = resolved else { continue }
      let bookmark: Data
      if stale, let updated = try? url.bookmarkData() {
        bookmark = updated
      } else {
        bookmark = data
      }
      result.append(.init(url: url, bookmark: bookmark))
    }
    return result
  }
#endif
}
