import AppKit
import GalleyCoreKit
import Observation
import os
import SwiftUI
import UniformTypeIdentifiers

/// Routes Finder double-click and `application(_:open:)` URLs into a
/// SwiftUI `WindowGroup(for: URL.self)`. The chicken-and-egg problem
/// here is that `openWindow(value:)` is a SwiftUI environment value —
/// only available inside a view — but `application(_:open:)` may fire
/// before any window has appeared. We buffer URLs until a window comes
/// up and installs its open handler, then flush.
///
/// Pure routing decisions live in `GalleyCoreKit/Routing/`
/// (`OpenURLRouter`, `WindowRegistry`, `LaunchURLBuffer`,
/// `PendingScrollLines`, `URLNormalizer`). This delegate is the AppKit
/// bridge: it owns the `NSWindow`-keyed maps, drives state mutations
/// in response to AppKit callbacks, and interprets the router's
/// `DispatchAction` against the live `NSApplication`.
///
/// Also tracks recently-opened URLs so the File > Open Recent menu can
/// observe them. `WindowGroup` doesn't get the system Open Recent for
/// free (that menu is wired to NSDocument), so we surface
/// `NSDocumentController.shared.recentDocumentURLs` ourselves and
/// refresh it whenever we note a new URL or clear the list.
@MainActor
@Observable
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
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

  /// Closures the registry can't carry (they aren't `Sendable`). Keyed
  /// by the same `WindowID` as `windowsByID`. Each closure rebinds the
  /// owning window's WindowGroup binding + `DocumentModel` to a new
  /// URL — installed by `ContentView` at registration time.
  @ObservationIgnored
  private var rebindClosures: [WindowID: @MainActor (URL) -> Void] = [:]

  /// Reference to the shared `AppModel`, set by `ViewerApp` so
  /// `application(_:open:)` and friends can consult `openBehavior`
  /// without a SwiftUI environment lookup.
  @ObservationIgnored weak var appModel: AppModel?

  /// FIFO queue of hosts for the next `newTab` opens. Populated
  /// immediately before calling `openHandler`; each new window's
  /// `WindowAccessor` consumes one entry when it resolves an
  /// `NSWindow`. A queue (rather than a single slot) handles the
  /// multi-URL case from `application(_:open:)` where window
  /// creation is async w.r.t. the dispatch loop.
  @ObservationIgnored private var pendingTabHosts: [NSWindow] = []

  /// Active FTUE open panel, kept so we can cancel it when an
  /// incoming document rebinds the placeholder out from under the
  /// launch picker.
  @ObservationIgnored private weak var activeOpenPanel: NSOpenPanel?

  @ObservationIgnored
  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "ViewerAppDelegate")

  /// Mirrors `NSDocumentController.shared.recentDocumentURLs`. Updated
  /// whenever we record or clear a recent URL. Bind from the File
  /// menu's Open Recent submenu.
  private(set) var recentURLs: [URL] = []

  /// Set true when AppKit signals launch is complete. State
  /// restoration finishes before this fires, so the placeholder
  /// window can wait on this flag instead of a fixed timeout
  /// before deciding to show the FTUE open panel.
  private(set) var didFinishLaunching = false

  /// Parsed view of `CommandLine.arguments`. In production every flag
  /// is at its default, so the delegate behaves exactly as before.
  /// Tests that exec the built `.app` with `--ui-test-mode` (and
  /// friends) get deterministic, ephemeral behavior.
  @ObservationIgnored let launchArgs: LaunchArguments

  override init() {
    self.launchArgs = LaunchArguments.fromProcess()
    super.init()
    self.recentURLs = NSDocumentController.shared.recentDocumentURLs
    if let seed = launchArgs.seedFile {
      // Pure injection point — equivalent to the URL having arrived
      // via `application(_:open:)` immediately after launch. The
      // dispatch pipeline (registry, buffer drain, openHandler) is
      // unchanged from the production path.
      launchBuffer.append(seed)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      switch URLNormalizer.normalize(url) {
      case .openSettings:
        // Handled by `.onOpenURL` on the WindowGroup root view, which
        // calls SwiftUI's `openSettings()`. Skip here so it doesn't
        // collide with the document-open pipeline.
        continue
      case .document(let fileURL, let line):
        if let line {
          pendingScrolls.stash(line, for: fileURL)
          logger.debug("""
            Stashed scroll line \(line) for \
            \(fileURL.path, privacy: .public)
            """)
        }
        record(fileURL)
        dispatch(fileURL)
      case .unparseable(let original):
        logger.warning("""
          Could not parse inbound URL: \
          \(original.absoluteString, privacy: .public)
          """)
        record(original)
        dispatch(original)
      }
    }
  }

  /// Take and clear the pending scroll-to-line for `url`, if any.
  /// Called by ContentView at the bind sites for both initial open and
  /// in-place replace.
  func consumePendingScrollLine(for url: URL) -> Int? {
    let line = pendingScrolls.consume(for: url)
    if let line {
      logger.debug("""
        Consumed scroll line \(line) for \
        \(url.standardizedFileURL.path, privacy: .public)
        """)
    }
    return line
  }

  /// Single entry point all "open this URL" requests funnel through.
  /// Honors `Defaults.shared.openBehavior` when at least one window is
  /// already on screen; with no windows, every mode collapses to
  /// "spawn a new window" since there's no frontmost to tab onto.
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
      activeOpenPanel?.cancel(nil)
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
    // A window that's already bound to a URL at registration time is
    // a real document window — not a placeholder. Setting
    // `hasDocument` here (rather than waiting for `markWindowReady`)
    // lets `dispatch` and `runLaunchPicker` see the truth immediately,
    // before the model's binding completes asynchronously.
    registry.register(WindowRecord(
      id: id,
      hasDocument: initialURL != nil,
      currentURL: initialURL))
  }

  func unregisterWindow(_ window: NSWindow) {
    guard let id = idsByObject
      .removeValue(forKey: ObjectIdentifier(window)) else { return }
    registry.unregister(id)
    windowsByID.removeValue(forKey: id)
    rebindClosures.removeValue(forKey: id)
  }

  /// Flip a registration from "placeholder" to "real document window"
  /// so subsequent dispatches treat it as a valid tab host. Called
  /// once `model.documentURL` becomes non-nil for the first time.
  func markWindowReady(_ window: NSWindow) {
    guard let id = idsByObject[ObjectIdentifier(window)] else { return }
    registry.markReady(id)
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

  /// True when at least one registered window already has a document
  /// bound. The launch placeholder uses this to decide whether to
  /// dismiss itself instead of running the FTUE open panel — if a
  /// real document window has appeared (from a URL dispatched out of
  /// `application(_:open:)` or anywhere else), the placeholder is
  /// redundant.
  func hasAnyDocumentWindow() -> Bool {
    registry.hasAnyDocumentWindow
  }

  /// Reverse-lookup helper for `dispatch`: given a live `NSWindow`,
  /// return the `WindowID` we registered it under (if still tracked).
  private func windowID(for window: NSWindow) -> WindowID? {
    idsByObject[ObjectIdentifier(window)]
  }

  /// Allow an untitled placeholder window so SwiftUI has a host view
  /// up early enough to install the `openWindow` handler — otherwise
  /// URLs queued during launch never flush. The placeholder shows a
  /// "no document" prompt; users get File > Open / Open Recent there.
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
    true
  }

  /// Opt in to secure state restoration so macOS persists the open
  /// windows (and SwiftUI persists their `@SceneStorage` payloads)
  /// across launches without warning about insecure coding.
  func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }

  /// Called by the first SwiftUI view that comes up. Installs the
  /// `openWindow` action and flushes any URLs queued during launch.
  /// Returns `true` when pending URLs were flushed — the caller can
  /// use that signal to drop a placeholder welcome window since real
  /// document windows are about to appear.
  @discardableResult
  func install(_ handler: @escaping (URL) -> Void) -> Bool {
    let hadPending = !launchBuffer.isEmpty
    openHandler = handler
    for url in launchBuffer.drain() { handler(url) }
    return hadPending
  }

  /// Open one or more files via NSOpenPanel and dispatch them through
  /// the same routing path as Finder opens.
  func presentOpenPanel() {
    Task { application(NSApp, open: await runOpenPanel()) }
  }

  /// Run NSOpenPanel and return the picked URLs without dispatching
  /// anywhere. Used by the launch flow so the caller can load the file
  /// into the placeholder window rather than spawning a new one.
  ///
  /// Uses the async `begin` form rather than `runModal` because
  /// `runModal` cannot start inside a SwiftUI/CoreAnimation transaction
  /// commit — the launch picker fires from `.task(id:)` which runs
  /// during view update.
  func runOpenPanel() async -> [URL] {
    let panel = NSOpenPanel()
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

  /// Stay alive after the last window closes — the user can launch
  /// the open panel again from File > Open.
  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  /// Open a single previously-opened URL through the same dispatch
  /// path as Finder/NSOpenPanel — used by the Open Recent menu.
  func openRecent(_ url: URL) {
    application(NSApp, open: [url])
  }

  /// Record a URL as recently opened. Called from
  /// `application(_:open:)`, but also exposed so other entry points
  /// (e.g. ContentView's task on initial bind) can keep the list in
  /// sync.
  func record(_ url: URL) {
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
    recentURLs = NSDocumentController.shared.recentDocumentURLs
  }

  func clearRecents() {
    NSDocumentController.shared.clearRecentDocuments(nil)
    recentURLs = NSDocumentController.shared.recentDocumentURLs
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
