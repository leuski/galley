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

  /// FIFO queue of hosts for the next `newTab` opens. Populated
  /// immediately before calling `openHandler`; each new window's
  /// `WindowAccessor` consumes one entry when it resolves an
  /// `NSWindow`. A queue (rather than a single slot) handles the
  /// multi-URL case where window creation is async w.r.t. the
  /// dispatch loop.
  @ObservationIgnored private var pendingTabHosts: [NSWindow] = []

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
  func handleOpenURLs(
    _ urls: [URL],
    onSettingsRequested: () -> Void = {}
  ) {
    for url in urls {
      switch URLNormalizer.normalize(url) {
      case .openSettings:
        onSettingsRequested()
      case .document(let fileURL, let line):
        if let line {
          pendingScrolls.stash(line, for: fileURL)
        }
        dispatch(fileURL)
      case .unparseable(let original):
        logger.warning("""
          Could not parse inbound URL: \
          \(original.absoluteString, privacy: .public)
          """)
        dispatch(original)
      }
    }
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
        pendingTabHosts.append(host)
      }
      openHandler?(url)

    case .focusExisting(let id):
      windowsByID[id]?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      rebindClosures[id]?(url)
    }
  }

  // MARK: - Window registry

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
  }

  func unregisterWindow(_ window: NSWindow) {
    guard let id = idsByObject
      .removeValue(forKey: ObjectIdentifier(window)) else { return }
    registry.unregister(id)
    windowsByID.removeValue(forKey: id)
    rebindClosures.removeValue(forKey: id)
  }

  /// Track the URL each window is currently bound to. ContentView
  /// calls this whenever `model.documentURL` changes so `dispatch`
  /// can short-circuit re-opens of an already-visible document.
  func updateCurrentURL(_ window: NSWindow, _ url: URL?) {
    guard let id = idsByObject[ObjectIdentifier(window)] else { return }
    registry.updateCurrentURL(id, url)
  }

  /// Consume the oldest pending `newTab` host. The new window calls
  /// this after attaching, then merges itself onto the returned host.
  func consumePendingTabHost() -> NSWindow? {
    pendingTabHosts.isEmpty ? nil : pendingTabHosts.removeFirst()
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

  /// Pre-seed the launch buffer with a URL. Used by the test-mode
  /// `--seed-file` injection point — equivalent to the URL having
  /// arrived via `application(_:open:)` immediately after launch.
  func enqueueAtLaunch(_ url: URL) {
    launchBuffer.append(url)
  }
}
