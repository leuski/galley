//
//  Defaults.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import Foundation
import GalleyCoreKit
import SwiftUI
import OSLog

/// App-wide rendering preferences for the Viewer. Renderer selection
/// (catalog discovery + persisted ID), template store, server config,
/// and window-open behavior all live here, separately from any single
/// window's `DocumentModel`. Windows read the active renderer + template
/// at render time, so the user can switch globally and have every open
/// document re-render.
///
/// Backed by `@ObservableDefaults` on `UserDefaults.standard` — for
/// the Viewer that's `~/Library/Preferences/net.leuski.galley.plist`,
/// the same plist the Server reaches via
/// `UserDefaults(suiteName: "net.leuski.galley")`. (The Viewer cannot
/// itself open a suite with that name: `UserDefaults(suiteName:)`
/// returns nil when the suite equals the calling app's own bundle
/// id.) `limitToInstance: false` widens the local observer to react
/// to any UserDefaults change in this process; cross-process change
/// signaling is handled separately by `DefaultsBroadcast` (Darwin
/// notification) because `UserDefaults.didChangeNotification` is
/// process-local.
@ObservableDefaults(limitToInstance: false)
final class Defaults: GalleyRenderDefaults,
                      HTTPServerDefaults,
                      BroadcastedDefaults,
                      GalleyEditorDefaults
{
  var renderer: ProcessorChoice.PersistentSelectionRepresentation?
  var template: TemplateChoice.PersistentSelectionRepresentation?
  var enablePerDocumentOverrides: Bool = false
  var openBehavior: OpenBehavior = .newWindow
  /// Per-window persisted state, keyed by `DocumentSceneID.description`.
  /// The window-keyed half of document store — SwiftUI restores the
  /// `WindowGroup` value (the id), and the window rehydrates its
  /// document from this map. Replaces the old `@SceneStorage("history")`
  /// slot (broken on visionOS). See docs/rebuild-document-windowing.md.
  private var windowSnapshots: [String: Data] = [:]
  /// Per-file persisted state, keyed by `fileKey(_:)`. The
  /// url-keyed half of document store: a fresh window opening a known
  /// file re-seeds its zoom/scroll/TOC/choices from here. Same
  /// `Snapshot` type as `windowSnapshots`; the nav stack collapses to
  /// the single file.
  private var fileSnapshots: [String: DocumentModel.Snapshot] = [:]
  /// When on, the active page's background color is painted behind
  /// the window glass via `.containerBackground(_:for:.window)` so
  /// the toolbar/ornament/sidebar chrome sample it through their
  /// material. When off, the window keeps the platform's default
  /// surface (system window background on macOS; plain glass on
  /// visionOS). Promoted out of macOS-only scope so visionOS reads
  /// the same key.
  var tintWindowWithPageBackground: Bool = true
  /// Per-template page background colors, captured by
  /// `BackgroundColorBridge` after each render. Used by
  /// `Template.backgroundState` so a freshly-opened tab can paint
  /// the chrome with the right tint immediately, and by FindBar /
  /// DocumentView for the same reason.
  var templateBackgroundColors: [String: TemplateBackgroundState]
  = [:]
  /// Most recent opaque page bg observed by *any* template. Used as
  /// a global fallback when the currently-resolved template hasn't
  /// reported yet — opening a new tab using a never-seen template
  /// hydrates with this last-seen color instead of flashing to the
  /// system default. Empty string means no color has been observed
  /// in this session or any past session yet.
  var lastTemplateBackgroundColor: TemplateBackgroundState
  = .unresolved
  /// Whether the bottom `StatusBar` HUD (word count, reading time,
  /// heading count) is visible in document windows. Global pref —
  /// the same toggle applies to every open window.
  var showsStatusBar: Bool = false
  /// Words-per-minute used to estimate reading time in the status
  /// bar. 200 is the rough middle of the literature on prose reading
  /// speed (Marked 2 defaults to 220, Hemingway uses 250).
  var readingWordsPerMinute: Int = 200

#if os(macOS)
  var editor: EditorPolicy.PersistentSelectionRepresentation?
  var editorOtherApplicationPath: String?
  var editorCustomURL = InvocationStyle.defaultCustomURL
#endif

  /// Persisted Open Recent entries — the single source of truth for
  /// the recents list on both platforms. Each entry carries a URL
  /// and — for local file URLs only — a bookmark blob that lets us
  /// re-resolve a fresh (security-scoped, where the OS requires it)
  /// URL after relaunch. Remote (http(s), galley://) URLs persist as
  /// URL-only entries. On macOS `RecentDocumentsModel` mirrors this
  /// list into `NSDocumentController` so the Dock's Recent Documents
  /// menu stays in sync.
  var recentEntries: [RecentDocumentEntry] = []

  /// Persisted (serialized) form of the global color-scheme choice.
  /// `nil` keeps the catalog default (`ColorSchemeStore.defaultValue`,
  /// i.e. `.light`). Mirror of the template/renderer keys — the
  /// concrete `ColorSchemeChoice` reads through here at boot, and
  /// `AppModel` writes back via `bindPersistent`. Stored on both
  /// platforms so the shared plist round-trips cleanly; only visionOS
  /// surfaces the setting in UI.
  var colorScheme: ColorSchemeChoice.PersistentSelectionRepresentation?

  /// Hash of the Galley.app bundle the Server saw at its launch.
  /// Published by the Server (via the shared `net.leuski.galley`
  /// plist), read by the Viewer on its launch to detect a stale
  /// Server. Cleared by the Viewer before terminating a stale Server
  /// so a re-read during the kill window doesn't re-trigger the reap.
  var serverGalleyHash: String?

  /// OS-assigned port of the running Galley Server's HTTP listener.
  /// Published by the Server when it binds, cleared (set to 0) when
  /// it stops. The Viewer doesn't currently read this, but the
  /// conformance to `GalleyNetworkDefaults` keeps the shared-suite
  /// contract honest and surfaces `serverEndpointURL` for any future
  /// reader. Quicklook reads the same plist through its own
  /// `Defaults` class.
  var serverHTTPPort: UInt16 = 0

  @MainActor static let shared = Defaults()

  @Ignore let broadcaster = DefaultsBroadcast(
    suiteName: GalleyConstants.suiteName)
  @Ignore var accessTimes = Set<String>()

  subscript (snapshot key: DocumentSceneID) -> Data? {
    get {
      let key = key.description
      accessTimes.insert(key)
      return windowSnapshots[key]
    }
    set {
      let key = key.description
      accessTimes.insert(key)
      windowSnapshots[key] = newValue
    }
  }

  /// Stable plist key for a URL: file URLs canonicalize (standardized +
  /// symlink-resolved) so two paths to the same file share state;
  /// remote URLs keep host + path (`safe.path()` would drop the host).
  private func fileKey(_ url: URL) -> String {
    url.isFileURL ? url.safe.path() : url.absoluteString
  }

  subscript (snapshot key: URL) -> DocumentModel.Snapshot? {
    get {
      let key = fileKey(key)
      return fileSnapshots[key]
    }
    set {
      let key = fileKey(key)
      fileSnapshots[key] = newValue
    }
  }

  private func purgeSceneSnapshots() {
    windowSnapshots = windowSnapshots.filter { key, _ in
      accessTimes.contains(key) }
  }

  init() {
    observerStarter()
    Task { @MainActor in
      do {
        // purge all snapshots that have not been accessed in some time
        // after the init -- it means they have not been restored.
        try await Task.sleep(for: .seconds(15))
        Self.shared.purgeSceneSnapshots()
      } catch {
        // ignore
      }
    }
  }

}
