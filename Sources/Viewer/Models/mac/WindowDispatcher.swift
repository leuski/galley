#if os(macOS)
import AppKit
import GalleyCoreKit
import KosmosAppKit
import KosmosCore
import Observation
import OSLog
import SwiftUI

/// Owns Galley's inbound-document-URL routing policy and its
/// AppKit-side state, layered on the shared `OpenURLCoordinator`.
///
/// The generic mechanism — the launch buffer, the `WindowRegistry`, the
/// `NSWindow ↔ WindowID` maps, the `willCloseNotification` observers, the
/// `dispatch → decide → apply` pipeline — lives in `KosmosAppKit`'s
/// `OpenURLCoordinator` and is shared with Dot. This class supplies the
/// Galley-specific *policy*: the `OpenURLRouter` decision (`decide`), the
/// `DispatchAction` execution (`apply`, the only AppKit-window-mutating
/// code), and the bits the generic layer knows nothing about — help-window
/// routing, `galley://` parsing, per-window rebind closures, the
/// `newTab` host queue, and scroll-line stashing.
///
/// `@Observable @MainActor`, injected via `.environment()` so SwiftUI
/// views (welcome, content view, file commands) reach it without
/// `NSApplication.delegate` casts.
@MainActor
@Observable
final class WindowDispatcher {
  /// Closure that brings the singleton Help window to front. Set by
  /// the bootstrap modifier; captures `\.openWindow`. Help URLs bypass
  /// the regular routing pipeline entirely — they are not registered
  /// in the coordinator, never tab-merge, never focus-existing onto a
  /// doc window. The URL to display is stored in `currentHelpURL` and
  /// observed by `HelpWindowView`.
  @ObservationIgnored private(set) var helpHandler: (() -> Void)?

  /// URL the singleton Help window should display. The Help scene is
  /// a SwiftUI `Window(id: "help")` — singular, not a
  /// `WindowGroup<URL>`, so SwiftUI cannot persist a URL binding for
  /// us. `handleOpenURLs` writes here before triggering `helpHandler`;
  /// `HelpWindowView` observes the value and binds it into the
  /// underlying `DocumentView`.
  var currentHelpURL: URL?

  /// Shared, app-agnostic routing mechanism. Galley keys windows by the
  /// Kosmos `WindowID` so the local registry id matches the id it sends
  /// over the Kosmos wire — the coordinator itself never sees Kosmos.
  @ObservationIgnored
  private let coordinator: OpenURLCoordinator<WindowID, DispatchAction>

  @ObservationIgnored private let router = OpenURLRouter()
  @ObservationIgnored private let idAllocator = WindowIDAllocator()
  @ObservationIgnored private var pendingScrolls = PendingScrollLines()

  /// Per-window rebind closures the registry can't carry (they aren't
  /// `Sendable`). Each rebinds the owning window's WindowGroup binding +
  /// `DocumentModel` to a new URL — installed by `ContentView` at
  /// registration time, dropped via the coordinator's `onUnregister`
  /// hook when the window closes.
  @ObservationIgnored
  private var rebindClosures: [WindowID: @MainActor (URL) -> Void] = [:]

  /// Pending `newTab` merges keyed by the URL that triggered them.
  /// Populated immediately before asking the coordinator to spawn; each
  /// new window's `WindowAccessor` consumes the entry whose URL matches
  /// its bound `fileURL`. URL-match (rather than FIFO) is what makes
  /// merging robust against duplicate dispatches: when `.onOpenURL`
  /// fan-out or rapid back-to-back opens push the host more times than
  /// SwiftUI ends up creating windows (because `openWindow(value:)`
  /// dedupes on the in-flight URL), the leftover entries sit in the
  /// queue without poisoning the next legitimate open onto a different
  /// URL.
  @ObservationIgnored
  private var pendingTabHosts: [(url: URL, host: NSWindow)] = []

  @ObservationIgnored
  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "WindowDispatcher")

  init() {
    let router = router
    let allocator = idAllocator
    let coordinator = OpenURLCoordinator<WindowID, DispatchAction>(
      makeID: { allocator.next() },
      decide: { url, registry, handlerInstalled, mainWindow, keyWindow in
        router.decide(
          for: url,
          behavior: Defaults.shared.openBehavior,
          registry: registry,
          handlerInstalled: handlerInstalled,
          mainWindow: mainWindow,
          keyWindow: keyWindow)
      })
    self.coordinator = coordinator
    // `self` is fully initialized here (every stored property has a
    // value), so the execution + cleanup closures may capture it.
    coordinator.apply = { [weak self] action, url in
      self?.apply(action, for: url)
    }
    coordinator.onUnregister = { [weak self] id in
      self?.rebindClosures[id] = nil
    }
  }

  /// Single entry point for handling a batch of inbound URLs (from
  /// Finder, LaunchServices, Open Recent, etc.). Each URL is
  /// normalized (galley://path?line=N → file URL with stashed line),
  /// then routed through the coordinator's decide/apply pipeline.
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
      switch url.galleyRequest {
      case .openSettings(let tab):
        onSettingsRequested(tab)
      case .document(let info):
        // Help docs route to the singleton Help window — never
        // registered with the routing system, never tab-merged,
        // never recorded in Open Recent (the latter is enforced
        // by `RecentDocumentsModel.record` independently). If
        // `helpHandler` isn't installed yet (pre-launch race),
        // fall through to the regular dispatch path rather than
        // dropping the URL.
        if info.url.isInMainBundle, let helpHandler {
          currentHelpURL = info.url
          helpHandler()
          continue
        }
        if let line = info.scrollLine {
          pendingScrolls.stash(line, for: info.url)
        }
        coordinator.dispatch(info.url)
      case .none:
        logUnparseableURL(url)
        coordinator.dispatch(url)
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

  /// Interpret a `DispatchAction` against the live `NSApplication`.
  /// Wired into the coordinator as its `apply` closure — the one place
  /// `NSWindow`/`NSApp` mutation happens; the decision itself is pure
  /// (`OpenURLRouter`, tested in `Tests/GalleyCoreKitTests/Routing/`).
  private func apply(_ action: DispatchAction, for url: URL) {
    switch action {
    case .queue:
      coordinator.enqueue(url)

    case .openNew:
      coordinator.spawn(url)

    case .rebind(let id):
      rebindClosures[id]?(url)

    case .tabOnto(let id):
      if let host = coordinator.window(for: id) {
        pendingTabHosts.append((url: url, host: host))
      }
      coordinator.spawn(url)

    case .focusExisting(let id):
      coordinator.window(for: id)?.makeKeyAndOrderFront(nil)
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
  ///      it asked the coordinator to spawn this one. Match by URL so
  ///      a stale queue entry from a deduped `openWindow(value:)` or
  ///      fan-out `.onOpenURL` doesn't poison an unrelated open —
  ///      see `consumePendingTabHost(for:)`.
  ///   3. Tab "+" hook — `NewTabAction.install(on:)` patches the
  ///      AppKit selector that SwiftUI's `WindowGroup<URL>` mishandles,
  ///      so the user's "+" click runs the Open panel and merges
  ///      picks as tabs. Idempotent at the class level.
  ///   4. Register — wire up the rebind closure that the routing
  ///      adapter will call for `replaceCurrent` and `focusExisting`
  ///      paths; the coordinator installs the `willCloseNotification`
  ///      cleanup.
  ///
  /// Detach is the asymmetric one-liner `unregisterWindow(_:)`. The
  /// coordinator's close observer auto-fires `unregisterWindow` on tab
  /// close — safe to call twice (unknown ids are no-ops).
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
    let id = coordinator.registerWindow(window, initialURL: initialURL)
    rebindClosures[id] = rebind
  }

  func unregisterWindow(_ window: NSWindow) {
    coordinator.unregisterWindow(window)
  }

  /// Track the URL each window is currently bound to. ContentView
  /// calls this whenever `model.documentURL` changes so the router can
  /// short-circuit re-opens of an already-visible document.
  func updateCurrentURL(_ window: NSWindow, _ url: URL?) {
    coordinator.updateCurrentURL(window, url)
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
    guard coordinator.openHandler != nil else { return }
    for url in urls {
      switch url.galleyRequest {
      case .openSettings:
        continue
      case .document(let info):
        if let line = info.scrollLine {
          pendingScrolls.stash(line, for: info.url)
        }
        pendingTabHosts.append((url: info.url, host: host))
        coordinator.spawn(info.url)
      case .none:
        pendingTabHosts.append((url: url, host: host))
        coordinator.spawn(url)
      }
    }
  }

  /// True when at least one document window is registered.
  func hasAnyDocumentWindow() -> Bool {
    coordinator.hasRegisteredWindow
  }

  /// Called by the welcome scene's `.task` once the first SwiftUI
  /// view is alive. Installs the `openWindow` action and flushes
  /// any URLs queued during launch (Galley drains at install: each
  /// buffered URL spawns a window via `openWindow(value:)`).
  ///
  /// Returns `true` when pending URLs were flushed — informational;
  /// no caller currently branches on it.
  @discardableResult
  func install(_ handler: @escaping (URL) -> Void) -> Bool {
    coordinator.install(handler)
    return coordinator.flushLaunchBuffer()
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
    coordinator.enqueue(url)
  }
}

#endif
