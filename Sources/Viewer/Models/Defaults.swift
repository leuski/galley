//
//  Defaults.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import Foundation
import GalleyCoreKit
import SwiftUI
import os

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
final class Defaults: GalleyRenderDefaults {
  @DefaultsKey var renderer: String?
  @DefaultsKey var template: String?
  @DefaultsKey var enablePerDocumentOverrides: Bool = false
  @DefaultsKey var openBehavior: OpenBehavior = .newWindow
  @DefaultsKey var perFileStateStore: [String: PerFileState] = [:]
  /// When on, the active page's background color is painted behind
  /// the window glass via `.containerBackground(_:for:.window)` so
  /// the toolbar/ornament/sidebar chrome sample it through their
  /// material. When off, the window keeps the platform's default
  /// surface (system window background on macOS; plain glass on
  /// visionOS). Promoted out of macOS-only scope so visionOS reads
  /// the same key.
  @DefaultsKey var tintWindowWithPageBackground: Bool = true
  /// Per-template page background colors, captured by
  /// `BackgroundColorBridge` after each render. Used by
  /// `Template.backgroundState` so a freshly-opened tab can paint
  /// the chrome with the right tint immediately, and by FindBar /
  /// DocumentView for the same reason.
  @DefaultsKey var templateBackgroundColors: [String: TemplateBackgroundState]
  = [:]
  /// Most recent opaque page bg observed by *any* template. Used as
  /// a global fallback when the currently-resolved template hasn't
  /// reported yet — opening a new tab using a never-seen template
  /// hydrates with this last-seen color instead of flashing to the
  /// system default. Empty string means no color has been observed
  /// in this session or any past session yet.
  @DefaultsKey var lastTemplateBackgroundColor: TemplateBackgroundState
  = .unresolved
  /// Whether the bottom `StatusBar` HUD (word count, reading time,
  /// heading count) is visible in document windows. Global pref —
  /// the same toggle applies to every open window.
  @DefaultsKey var showsStatusBar: Bool = false
  /// Words-per-minute used to estimate reading time in the status
  /// bar. 200 is the rough middle of the literature on prose reading
  /// speed (Marked 2 defaults to 220, Hemingway uses 250).
  @DefaultsKey var readingWordsPerMinute: Int = 200

#if os(macOS)
  @DefaultsKey var editor: EditorChoice.Element = .preset(.bbedit)
#endif

  /// Persisted (serialized) form of the global color-scheme choice.
  /// `nil` keeps the catalog default (`ColorSchemeStore.defaultValue`,
  /// i.e. `.light`). Mirror of the template/renderer keys — the
  /// concrete `ColorSchemeChoice` reads through here at boot, and
  /// `AppModel` writes back via `bindPersistent`. Stored on both
  /// platforms so the shared plist round-trips cleanly; only visionOS
  /// surfaces the setting in UI.
  @DefaultsKey var colorScheme: String?

  @MainActor static let shared = Defaults()

  /// Synchronize the `@ObservableDefaults` macro's per-property cache
  /// with the actual on-disk values. Must be called once at app boot,
  /// BEFORE any SwiftUI layout pass.
  ///
  /// Why: the macro maintains a `_<property>` cache that backs its
  /// `userDefaultsDidChange` handler. The cache is initialized to each
  /// property's literal default (not the persisted value) and is only
  /// updated from inside the notification handler. So the FIRST
  /// `UserDefaults.didChangeNotification` received in the process
  /// triggers `withMutation` for every property whose persisted value
  /// differs from its declared default.
  ///
  /// WebKit's `+[NSParagraphArbitrator initialize]` calls
  /// `[NSUserDefaults registerDefaults:]` the first time `WKWebView`
  /// initializes, which posts that notification synchronously from
  /// inside a SwiftUI layout pass (`sizeThatFits` → `makeNSViewController`
  /// → `WKWebView.initWithFrame:configuration:`). The resulting
  /// `withMutation` re-enters `GraphHost.flushTransactions` and trips
  /// the `AG::Graph::value_set` precondition.
  ///
  /// Posting one synchronous notification during boot warms the cache
  /// so the WebKit-triggered notification finds no diffs and skips
  /// the mutation entirely.
  @MainActor static func warmCache() {
    _ = Defaults.shared
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: UserDefaults.standard)
  }
}
