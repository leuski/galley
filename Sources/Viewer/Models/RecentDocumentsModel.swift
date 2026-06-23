import GalleyCoreKit
import Observation
import SwiftUI
import KosmosAppKit

/// File URLs may resolve to differently-formed paths after
/// re-resolution (`/private/var` vs `/var`, scoped vs not). Compare
/// canonical FS paths there; remote URLs have no such concern and
/// compare by absolute string.
private extension URL {
  var key: String {
    isFileURL ? safe.path : absoluteString
  }
}

/// Persisted form of a recent entry. File URLs carry a bookmark blob
/// so a fresh URL can be re-resolved after relaunch — security-scoped
/// where the OS requires it (visionOS), a plain re-resolution where it
/// doesn't (unsandboxed macOS). Remote URLs (http(s), galley://, etc.)
/// carry only the URL — they don't need or support bookmarks.
struct RecentDocumentEntry: Codable, Hashable, Sendable {
  let url: URL
  let bookmark: Data?

  init(url: URL, bookmark: Data?) {
    self.url = url
    self.bookmark = bookmark
  }

  init?(url: URL) {
    if url.isFileURL {
      // The picker grants security scope on the URL we receive (and on
      // unsandboxed macOS a plain bookmark works just as well);
      // bookmarkData captures it so we can re-resolve after relaunch.
      // If bookmark creation fails, bail rather than persisting a file
      // URL we won't be able to reopen.
      guard let data = try? url.bookmarkData() else { return nil }
      self.init(url: url, bookmark: data)
    } else {
      self.init(url: url, bookmark: nil)
    }
  }

  var resolved: RecentDocumentEntry? {
    guard let data = bookmark else { return self }
    var stale = false
    guard let resolved = try? URL(
      resolvingBookmarkData: data,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
    else { return nil }
    guard stale, let updated = try? url.bookmarkData() else { return self }
    return RecentDocumentEntry(url: resolved, bookmark: updated)
  }
}

/// Recently-opened-document list surfaced by File > Open Recent (macOS)
/// and by the welcome screen + More > Open Recent menu (visionOS).
///
/// `Defaults.recentEntries` is the one and only store — this type holds
/// no copy of its own; `entries`/`urls` read straight through it and
/// mutations write straight back. The list is owned here rather than by
/// `NSDocumentController` because SwiftUI's `WindowGroup` installs no
/// system Open Recent menu — both platforms build that menu from
/// `urls`. On macOS we additionally mirror the list into
/// `NSDocumentController` on every change so the Dock's Recent
/// Documents submenu stays in sync.
///
/// File entries persist a bookmark alongside the URL and re-resolve at
/// open time; remote entries round-trip as URL-only. Constructed once
/// by the app's `@main`.
@MainActor
@Observable
final class RecentDocumentsModel {
  /// URLs ordered most-recent-first, derived from `entries`. Bound by
  /// the menu / welcome-screen UI.
  var urls: [URL] { Defaults.shared.recentEntries.map(\.url) }

  /// Cap matching the macOS system default for recent items. visionOS
  /// has no equivalent of System Settings → Desktop & Dock → Recent
  /// items, so the same constant governs both.
  static let maxItems = 10

  init() {
    update(Defaults.shared.recentEntries
      .compactMap { entry in entry.resolved })
  }

  private func entries(without url: URL) -> [RecentDocumentEntry] {
    let key = url.key
    return Defaults.shared.recentEntries
      .filter { entry in entry.url.key != key }
  }

  private func entry(with url: URL) -> RecentDocumentEntry? {
    let key = url.key
    return Defaults.shared.recentEntries
      .first { entry in entry.url.key == key }
  }

  /// Record a URL as recently opened.
  func record(_ url: URL) {
    guard
      !url.isInMainBundle,
      let entry = RecentDocumentEntry(url: url)
    else { return }
    update([entry] + entries(without: url))
  }

  /// Clear the recents list. Called from File > Open Recent >
  /// Clear Menu (macOS) and the Open Recent submenu footer
  /// (visionOS).
  func clearAll() {
    update([])
  }

  /// Resolve a recent entry and return a URL the caller can bind to its
  /// `WindowGroup` slot. For file entries that means re-resolving the
  /// bookmark (and starting security-scoped access where the OS
  /// requires it); for remote entries it's the stored URL as-is.
  /// Returns nil for a dead file entry (bookmark unresolvable) and
  /// prunes it as a side effect. Refreshes the on-disk bookmark when
  /// resolution reports stale data, and re-prepends the entry so
  /// reopening promotes it.
  func resolveRecentURL(_ url: URL) -> URL? {
    guard let entry = entry(with: url) else { return nil }
    guard let entry = entry.resolved else {
      update(entries(without: url))
      return nil
    }
    if entry.bookmark != nil {
      _ = entry.url.startAccessingSecurityScopedResource()
    }
    update([entry] + entries(without: url))
    return entry.url
  }

  /// Drop one entry by its resolved URL. Surfaced from the
  /// welcome-screen context menu.
  func remove(_ url: URL) {
    update(entries(without: url))
  }

  /// Write the list to its only store and re-sync the system recents.
  private func update<S>(_ newEntries: S)
  where S: Collection, S.Element == RecentDocumentEntry
  {
    let new = Array(newEntries.prefix(Self.maxItems))
    guard Defaults.shared.recentEntries != new else { return }
    Defaults.shared.recentEntries = new
    /// Rebuild `NSDocumentController`'s recent-documents list (and thus
    /// the Dock's Recent Documents submenu) from the given entries. No-op
    /// off macOS. `noteNewRecentDocumentURL` prepends, so we add
    /// oldest-first to land the most-recent entry at the top.
#if os(macOS)
    let controller = NSDocumentController.shared
    controller.clearRecentDocuments(nil)
    for url in new.map(\.url).reversed() {
      controller.noteNewRecentDocumentURL(url)
    }
#endif
  }
}
