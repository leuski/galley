import AppKit
import GalleyCoreKit
import Observation
import os
import SwiftUI

/// Owns the routing state and AppKit-bridge for inbound document URLs.
///
/// Pre-extraction this lived inside `ViewerAppDelegate` directly. The
/// extraction is mechanical: state types (registry, buffer, scrolls,
/// router, the `NSWindow ↔ WindowID` maps) move here, AppKit-only
/// `apply(_:for:)` interpreting `DispatchAction` against `NSApp`/
/// `NSWindow` moves with them. The `@Observable @MainActor` class is
/// injected via `.environment()` so SwiftUI views (welcome,
/// content view, file commands) talk to it directly without going
/// through `NSApplication.delegate` casts.
///
/// The pure routing decisions live in `GalleyCoreKit/Routing/`
/// (`OpenURLRouter`, `WindowRegistry`, `LaunchURLBuffer`, …); this
/// class is the AppKit adapter that holds the live `NSWindow`
/// references and converts router actions into AppKit calls.
@MainActor
@Observable
final class WindowDispatcher {
  @ObservationIgnored private(set) var openHandler: ((URL) -> Void)?

  /// Closure that brings the singleton Help window to front. Set by
  /// the bootstrap modifier; captures `\.openWindow`. Help URLs bypass
  /// the regular routing pipeline entirely — they are not registered
  /// in `WindowRegistry`, never tab-merge, never focus-existing onto
  /// a doc window. The URL to display is stored in `currentHelpURL`
  /// and observed by `HelpWindowView`.
  @ObservationIgnored private(set) var helpHandler: (() -> Void)?

  /// URL the singleton Help window should display. The Help scene is
  /// a SwiftUI `Window(id: "help")` — singular, not a
  /// `WindowGroup<URL>`, so SwiftUI cannot persist a URL binding for
  /// us. `handleOpenURLs` writes here before triggering `helpHandler`;
  /// `HelpWindowView` observes the value and binds it into the
  /// underlying `DocumentView`.
  var currentHelpURL: URL?

  @ObservationIgnored private var launchBuffer = LaunchURLBuffer()
  @ObservationIgnored private var registry = WindowRegistry()
  @ObservationIgnored private var pendingScrolls = PendingScrollLines()
  @ObservationIgnored private let router = OpenURLRouter()
  @ObservationIgnored private var idAllocator = WindowIDAllocator()

  /// Maps the live AppKit `NSWindow` (by `ObjectIdentifier`) to the
  /// stable `WindowID` we issued at registration time. Production-only
  /// table — the routing layer itself never sees `NSWindow`.
  @ObservationIgnored
  private var idsByObject: [ObjectIdentifier: WindowID] = [:]

  /// Reverse lookup so `apply(_:for:)` can dereference an opaque
  /// `WindowID` back to the live `NSWindow` it represents.
  @ObservationIgnored private var windowsByID: [WindowID: NSWindow] = [:]

  /// Closures the registry can't carry (they aren't `Sendable`).
  /// Each closure rebinds the owning window's WindowGroup binding +
  /// `DocumentModel` to a new URL — installed by `ContentView` at
  /// registration time.
  @ObservationIgnored
  private var rebindClosures: [WindowID: @MainActor (URL) -> Void] = [:]

  /// `NSWindow.willCloseNotification` observers, keyed by window id,
  /// so the dispatcher reliably unregisters a closed window even when
  /// SwiftUI's `WindowGroup` keeps the underlying `NSWindow` alive
  /// across close (`isReleasedWhenClosed = false` is the SwiftUI
  /// default for managed windows). Without this hook, closing a tab
  /// leaves a stale registration in the registry — the next reopen
  /// of the same URL routes to `.focusExisting` on the hidden,
  /// already-detached-from-its-tab-group window, which then surfaces
  /// as a floating standalone window instead of merging as a tab.
  @ObservationIgnored
  private var closeObservers: [WindowID: NSObjectProtocol] = [:]

  /// Pending `newTab` merges keyed by the URL that triggered them.
  /// Populated immediately before calling `openHandler`; each new
  /// window's `WindowAccessor` consumes the entry whose URL matches
  /// its bound `fileURL`. URL-match (rather than FIFO) is what makes
  /// merging robust against duplicate dispatches: when `.onOpenURL`
  /// fan-out or rapid back-to-back opens push the host more times
  /// than SwiftUI ends up creating windows (because `openWindow(
  /// value:)` dedupes on the in-flight URL), the leftover entries
  /// sit in the queue without poisoning the next legitimate open
  /// onto a different URL.
  @ObservationIgnored
  private var pendingTabHosts: [(url: URL, host: NSWindow)] = []

  @ObservationIgnored
  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "WindowDispatcher")

  init() {}

  /// Single entry point for handling a batch of inbound URLs (from
  /// Finder, LaunchServices, Open Recent, etc.). Each URL is
  /// normalized (galley://path?line=N → file URL with stashed line),
  /// then routed through the dispatcher's decide/apply pipeline.
  ///
  /// `galley://settings` URLs pass through to the caller via
  /// `onSettingsRequested` — the caller (ViewerApp's WindowGroup
  /// root) is responsible for invoking SwiftUI's `openSettings()`.
  /// The optional `SettingsTab` carries any `?tab=<id>` from the URL.
  func handleOpenURLs(
    _ urls: [URL],
    onSettingsRequested: (SettingsTab?) -> Void = { _ in }
  ) {
    for url in urls {
      switch url.galleyAction {
      case .openSettings(let tab):
        onSettingsRequested(tab)
      case .document(let fileURL, let line):
        // Help docs route to the singleton Help window — never
        // registered with the routing system, never tab-merged,
        // never recorded in Open Recent (the latter is enforced
        // by `RecentDocumentsModel.record` independently). If
        // `helpHandler` isn't installed yet (pre-launch race),
        // fall through to the regular dispatch path rather than
        // dropping the URL.
        if fileURL.isInMainBundle, let helpHandler {
          currentHelpURL = fileURL
          helpHandler()
          continue
        }
        if let line {
          pendingScrolls.stash(line, for: fileURL)
        }
        dispatch(fileURL)
      case .unparseable(let original):
        logUnparseableURL(original)
        dispatch(original)
      }
    }
  }

  private func logUnparseableURL(_ url: URL) {
    logger.warning("""
      Could not parse inbound URL: \
      \(url.absoluteString, privacy: .public)
      """)
  }

  /// Take and clear the pending scroll-to-line for `url`, if any.
  /// Called by ContentView at the bind sites for both initial open
  /// and in-place replace.
  func consumePendingScrollLine(for url: URL) -> Int? {
    pendingScrolls.consume(for: url)
  }

  /// Single entry point all "open this URL" requests funnel through.
  /// Honors `Defaults.shared.openBehavior` when at least one window
  /// is already on screen; with no windows, every mode collapses to
  /// "spawn a new window."
  func dispatch(_ url: URL) {
    let action = router.decide(
      for: url,
      behavior: Defaults.shared.openBehavior,
      registry: registry,
      handlerInstalled: openHandler != nil,
      mainWindow: NSApp.mainWindow.flatMap { windowID(for: $0) },
      keyWindow: NSApp.keyWindow.flatMap { windowID(for: $0) })
    apply(action, for: url)
  }

  /// Interpret a `DispatchAction` from the router against the live
  /// `NSApplication`. The split keeps the routing decisions pure
  /// (testable in `Tests/GalleyCoreKitTests/Routing/`) and limits
  /// `NSWindow`/`NSApp` coupling to this one method.
  private func apply(_ action: DispatchAction, for url: URL) {
    switch action {
    case .queue:
      launchBuffer.append(url)

    case .openNew:
      openHandler?(url)

    case .rebind(let id):
      rebindClosures[id]?(url)

    case .tabOnto(let id):
      if let host = windowsByID[id] {
        pendingTabHosts.append((url: url, host: host))
      }
      openHandler?(url)

    case .focusExisting(let id):
      windowsByID[id]?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      rebindClosures[id]?(url)
    }
  }

  // MARK: - Window registry

  /// Adopt a freshly-resolved `NSWindow` into the routing system.
  /// Symmetric counterpart of the multi-step ceremony that used to
  /// live inline in `DocumentView`'s `WindowAccessor.onAttach`.
  /// Performs:
  ///
  ///   1. Reveal — the window stays at `alphaValue = 0` until the
  ///      model has bound at least once. State restoration applies
  ///      the URL ~half a second after a view mounts, so we can't
  ///      predict the order of NSWindow resolve vs. `.task` firing.
  ///      If a previous fire already bound content, unhide right
  ///      away.
  ///   2. Tab merge — if this open came in under the `newTab`
  ///      open-behavior, the dispatcher queued the host window when
  ///      it asked SwiftUI to spawn this one. Match by URL so a
  ///      stale queue entry from a deduped `openWindow(value:)` or
  ///      fan-out `.onOpenURL` doesn't poison an unrelated open —
  ///      see `consumePendingTabHost(for:)`.
  ///   3. Tab "+" hook — `NewTabAction.install(on:)` patches the
  ///      AppKit selector that SwiftUI's `WindowGroup<URL>` mishandles,
  ///      so the user's "+" click runs the Open panel and merges
  ///      picks as tabs. Idempotent at the class level.
  ///   4. Register — wire up the rebind closure that the routing
  ///      adapter will call for `replaceCurrent` and `focusExisting`
  ///      paths, and install the `willCloseNotification` cleanup.
  ///
  /// Detach is the asymmetric one-liner `unregisterWindow(_:)`. The
  /// `willCloseNotification` observer installed during `register`
  /// auto-fires `unregisterWindow` on tab close — `unregisterWindow`
  /// is safe to call twice (registry treats unknown ids as no-ops).
  func adopt(
    _ window: NSWindow,
    fileURL: URL,
    didFirstBind: Bool,
    rebind: @escaping @MainActor (URL) -> Void
  ) {
    window.alphaValue = didFirstBind ? 1 : 0
    if let host = consumePendingTabHost(for: fileURL),
       host !== window,
       host.isVisible
    {
      host.addTabbedWindow(window, ordered: .above)
    }
    NewTabAction.install(on: window)
    registerWindow(window, initialURL: fileURL, rebind: rebind)
  }

  /// Called by every `ContentView` once its `NSWindow` resolves. The
  /// `rebind` closure swaps the window's WindowGroup binding and the
  /// underlying `DocumentModel` to a new URL.
  func registerWindow(
    _ window: NSWindow,
    initialURL: URL?,
    rebind: @escaping @MainActor (URL) -> Void
  ) {
    let id = idAllocator.next()
    idsByObject[ObjectIdentifier(window)] = id
    windowsByID[id] = window
    rebindClosures[id] = rebind
    registry.register(WindowRecord(id: id, currentURL: initialURL))
    // SwiftUI's `WindowGroup` leaves `isReleasedWhenClosed = false`
    // on managed windows, so closing a tab does NOT trigger
    // `viewWillMove(toWindow: nil)` on the contained subview — the
    // `WindowAccessor.onDetach` path can't be relied on. Observe the
    // notification directly so the registry stays in sync with the
    // user's perception of "this window is gone."
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.unregisterWindow(window)
      }
    }
    closeObservers[id] = observer
  }

  func unregisterWindow(_ window: NSWindow) {
    guard let id = idsByObject
      .removeValue(forKey: ObjectIdentifier(window)) else { return }
    registry.unregister(id)
    windowsByID.removeValue(forKey: id)
    rebindClosures.removeValue(forKey: id)
    if let observer = closeObservers.removeValue(forKey: id) {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Track the URL each window is currently bound to. ContentView
  /// calls this whenever `model.documentURL` changes so `dispatch`
  /// can short-circuit re-opens of an already-visible document.
  func updateCurrentURL(_ window: NSWindow, _ url: URL?) {
    guard let id = idsByObject[ObjectIdentifier(window)] else { return }
    registry.updateCurrentURL(id, url)
  }

  /// Consume the pending tab-merge host queued for `url`, if any.
  /// The new window calls this after attaching, then merges itself
  /// onto the returned host. Matching by URL (rather than FIFO order)
  /// keeps the queue robust against SwiftUI deduplicating
  /// `openWindow(value:)` calls or `.onOpenURL` fan-out producing
  /// more queue entries than created windows — stale entries sit
  /// there without poisoning unrelated opens.
  func consumePendingTabHost(for url: URL) -> NSWindow? {
    let target = url.standardizedFileURL.path
    guard let index = pendingTabHosts.firstIndex(where: {
      $0.url.standardizedFileURL.path == target
    }) else { return nil }
    return pendingTabHosts.remove(at: index).host
  }

  /// Open URLs as new tabs onto a specific host window. Used by the
  /// AppKit tab bar "+" button: the user's intent is unambiguous
  /// ("new tab here"), so we bypass `Defaults.shared.openBehavior`
  /// and the router's deduplication / focus-existing logic.
  func openAsTabs(_ urls: [URL], onto host: NSWindow) {
    guard let openHandler else { return }
    for url in urls {
      switch url.galleyAction {
      case .openSettings:
        continue
      case .document(let fileURL, let line):
        if let line { pendingScrolls.stash(line, for: fileURL) }
        pendingTabHosts.append((url: fileURL, host: host))
        openHandler(fileURL)
      case .unparseable(let original):
        pendingTabHosts.append((url: original, host: host))
        openHandler(original)
      }
    }
  }

  /// True when at least one document window is registered.
  func hasAnyDocumentWindow() -> Bool {
    !registry.isEmpty
  }

  /// Reverse-lookup helper for `dispatch`: given a live `NSWindow`,
  /// return the `WindowID` we registered it under (if still tracked).
  private func windowID(for window: NSWindow) -> WindowID? {
    idsByObject[ObjectIdentifier(window)]
  }

  /// Called by the welcome scene's `.task` once the first SwiftUI
  /// view is alive. Installs the `openWindow` action and flushes
  /// any URLs queued during launch.
  ///
  /// Returns `true` when pending URLs were flushed — informational;
  /// no caller currently branches on it.
  @discardableResult
  func install(_ handler: @escaping (URL) -> Void) -> Bool {
    let hadPending = !launchBuffer.isEmpty
    openHandler = handler
    for url in launchBuffer.drain() { handler(url) }
    return hadPending
  }

  /// Install the closure that brings the singleton Help window to
  /// front. Idempotent — subsequent calls re-capture the latest
  /// closure.
  func installHelp(_ handler: @escaping () -> Void) {
    helpHandler = handler
  }

  /// Pre-seed the launch buffer with a URL. Used by the test-mode
  /// `--seed-file` injection point — equivalent to the URL having
  /// arrived via `application(_:open:)` immediately after launch.
  func enqueueAtLaunch(_ url: URL) {
    launchBuffer.append(url)
  }
}
