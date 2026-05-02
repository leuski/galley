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
/// Also tracks recently-opened URLs so the File > Open Recent menu can
/// observe them. `WindowGroup` doesn't get the system Open Recent for
/// free (that menu is wired to NSDocument), so we surface
/// `NSDocumentController.shared.recentDocumentURLs` ourselves and
/// refresh it whenever we note a new URL or clear the list.
@MainActor
@Observable
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
  @ObservationIgnored private(set) var openHandler: ((URL) -> Void)?
  @ObservationIgnored private var pending: [URL] = []

  /// Reference to the shared `AppModel`, set by `ViewerApp` so
  /// `application(_:open:)` and friends can consult `openBehavior`
  /// without a SwiftUI environment lookup.
  @ObservationIgnored weak var appModel: AppModel?

  /// Window registry — each `ContentView` registers its `NSWindow`
  /// along with a closure that rebinds the window to a new URL. Used
  /// for the `replaceCurrent` open behavior, and to identify the
  /// frontmost window for the `newTab` handoff.
  @ObservationIgnored
  private var registrations: [ObjectIdentifier: WindowRegistration] = [:]

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

  /// Pending source-line scroll targets keyed by the standardized
  /// file path. Populated by `normalize(_:)` when an incoming
  /// `galley://` URL carries a `line=N` query parameter, drained by
  /// ContentView at bind time. Keyed by path string rather than URL
  /// because URL Hashable equality is sensitive to encoding/symlink
  /// differences between the URL we construct here and whatever
  /// SwiftUI hands back through the WindowGroup binding.
  @ObservationIgnored
  private var pendingScrollLines: [String: Int] = [:]

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

  override init() {
    super.init()
    self.recentURLs = NSDocumentController.shared.recentDocumentURLs
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      let normalized = normalize(url)
      record(normalized)
      dispatch(normalized)
    }
  }

  /// Translate inbound URLs into the canonical file URL the rest of
  /// the dispatch pipeline expects. `galley://...?line=N` becomes a
  /// plain `file://` URL with the line stashed in `pendingScrollLines`
  /// for ContentView to consume at bind time. Other URLs pass through
  /// unchanged.
  private func normalize(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "galley" else { return url }
    guard let components = URLComponents(
      url: url, resolvingAgainstBaseURL: false)
    else {
      logger.warning("""
        galley:// URL had no parseable components: \
        \(url.absoluteString, privacy: .public)
        """)
      return url
    }
    let path = components.path
    guard !path.isEmpty else {
      logger.warning("""
        galley:// URL had empty path: \
        \(url.absoluteString, privacy: .public)
        """)
      return url
    }
    let fileURL = URL(fileURLWithPath: path)
    let key = pendingKey(for: fileURL)
    if let value = components.queryItems?
      .first(where: { $0.name == "line" })?.value,
       let line = Int(value), line > 0
    {
      pendingScrollLines[key] = line
      logger.debug("""
        Stashed scroll line \(line) for \(key, privacy: .public)
        """)
    }
    return fileURL
  }

  /// Take and clear the pending scroll-to-line for `url`, if any.
  /// Called by ContentView at the bind sites for both initial open and
  /// in-place replace.
  func consumePendingScrollLine(for url: URL) -> Int? {
    let key = pendingKey(for: url)
    let line = pendingScrollLines.removeValue(forKey: key)
    if let line {
      logger.debug("""
        Consumed scroll line \(line) for \(key, privacy: .public)
        """)
    }
    return line
  }

  /// Stable lookup key for `pendingScrollLines`. Uses the standardized
  /// file path so `URL(fileURLWithPath:)` results match whatever URL
  /// SwiftUI/AppKit eventually hands back to ContentView, regardless
  /// of encoding/symlink/trailing-slash variations.
  private func pendingKey(for url: URL) -> String {
    url.standardizedFileURL.path
  }

  /// Single entry point all "open this URL" requests funnel through.
  /// Honors `AppModel.openBehavior` when at least one window is
  /// already on screen; with no windows, every mode collapses to
  /// "spawn a new window" since there's no frontmost to tab onto.
  func dispatch(_ url: URL) {
    let behavior = appModel?.openBehavior ?? .newWindow

    // Pre-launch (or no windows yet): only newWindow makes sense.
    // Queue if the SwiftUI handler isn't installed; otherwise just
    // hand off and let WindowGroup spawn a fresh window.
    guard let openHandler else {
      pending.append(url)
      return
    }

    // If a window is already showing this URL, route through its
    // rebind closure regardless of the configured behavior. SwiftUI's
    // `openWindow(value: url)` no-ops on an already-bound value — it
    // brings the existing scene to front but does not re-fire
    // `.task(id:)`, so the pending-scroll-line consume side never
    // runs. Going through `rebind` reaches `replaceDocument`, which
    // detects the same-URL case and just scrolls without resetting
    // history.
    if let match = registration(matching: url) {
      match.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      match.rebind(url)
      return
    }

    // Priority for every behavior: prefer a real document window
    // (tab/replace target) over the launch placeholder. A coexisting
    // placeholder will self-dismiss once it sees `hasAnyDocumentWindow`
    // is true. Falling back to the placeholder happens only when no
    // real doc window exists yet.
    switch behavior {
    case .newWindow:
      // If the only thing up is the placeholder, rebind it instead
      // of stacking another empty window. With a real doc window
      // present the user explicitly wants a new window, so just
      // spawn — the placeholder (if any) will dismiss itself.
      if frontmostDocumentRegistration() == nil,
         let placeholder = frontmostPlaceholderRegistration()
      {
        activeOpenPanel?.cancel(nil)
        placeholder.rebind(url)
        return
      }
      openHandler(url)

    case .newTab:
      // Tab onto the frontmost real document window. The freshly
      // spawned window's WindowAccessor will consume the queued host
      // and merge into its tab group.
      if let host = frontmostDocumentRegistration()?.window {
        pendingTabHosts.append(host)
        openHandler(url)
        return
      }
      // No real doc to tab onto — reuse the placeholder if present
      // (cancelling its FTUE picker), else spawn fresh.
      if let placeholder = frontmostPlaceholderRegistration() {
        activeOpenPanel?.cancel(nil)
        placeholder.rebind(url)
        return
      }
      openHandler(url)

    case .replaceCurrent:
      // Replace the frontmost real doc; if none, reuse a placeholder;
      // else spawn fresh.
      if let registration = frontmostDocumentRegistration() {
        registration.rebind(url)
        return
      }
      if let placeholder = frontmostPlaceholderRegistration() {
        activeOpenPanel?.cancel(nil)
        placeholder.rebind(url)
        return
      }
      openHandler(url)
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
    // A window that's already bound to a URL at registration time is
    // a real document window — not a placeholder. Setting
    // `hasDocument` here (rather than waiting for `markWindowReady`)
    // lets `dispatch` and `runLaunchPicker` see the truth immediately,
    // before the model's binding completes asynchronously.
    registrations[ObjectIdentifier(window)] = WindowRegistration(
      window: window,
      rebind: rebind,
      hasDocument: initialURL != nil,
      currentURL: initialURL)
  }

  func unregisterWindow(_ window: NSWindow) {
    registrations.removeValue(forKey: ObjectIdentifier(window))
  }

  /// Flip a registration from "placeholder" to "real document window"
  /// so subsequent dispatches treat it as a valid tab host. Called
  /// once `model.documentURL` becomes non-nil for the first time.
  func markWindowReady(_ window: NSWindow) {
    let key = ObjectIdentifier(window)
    if var reg = registrations[key] {
      reg.hasDocument = true
      registrations[key] = reg
    }
  }

  /// Track the URL each window is currently bound to. ContentView
  /// calls this whenever `model.documentURL` changes so `dispatch`
  /// can short-circuit re-opens of an already-visible document.
  func updateCurrentURL(_ window: NSWindow, _ url: URL?) {
    let key = ObjectIdentifier(window)
    if var reg = registrations[key] {
      reg.currentURL = url
      registrations[key] = reg
    }
  }

  /// First registration whose `currentURL` matches `url` by
  /// standardized file path. Used by `dispatch` to detect
  /// "this URL is already open in some window".
  private func registration(matching url: URL) -> WindowRegistration? {
    let target = url.standardizedFileURL.path
    return registrations.values.first { reg in
      guard reg.window != nil,
            let bound = reg.currentURL?.standardizedFileURL.path
      else { return false }
      return bound == target
    }
  }

  /// Consume the oldest pending `newTab` host. The new window calls
  /// this after attaching, then merges itself onto the returned host.
  func consumePendingTabHost() -> NSWindow? {
    pendingTabHosts.isEmpty ? nil : pendingTabHosts.removeFirst()
  }

  /// Pick the registered window that should receive the next "replace"
  /// or "new tab" request. Prefers the system's main window, falls
  /// back to the key window, then to any still-live registration.
  private func frontmostRegistration() -> WindowRegistration? {
    let keys = [NSApp.mainWindow, NSApp.keyWindow]
      .compactMap { $0 }
      .map { ObjectIdentifier($0) }
    for key in keys {
      if let registration = registrations[key],
         registration.window != nil
      {
        return registration
      }
    }
    return registrations.values.first { $0.window != nil }
  }

  private func frontmostRegisteredWindow() -> NSWindow? {
    frontmostRegistration()?.window
  }

  /// Frontmost registration whose window already has a document
  /// bound — i.e. is a real viewer tab host, not the alpha=0 launch
  /// placeholder.
  private func frontmostDocumentRegistration() -> WindowRegistration? {
    let keys = [NSApp.mainWindow, NSApp.keyWindow]
      .compactMap { $0 }
      .map { ObjectIdentifier($0) }
    for key in keys {
      if let reg = registrations[key],
         reg.hasDocument,
         reg.window != nil
      {
        return reg
      }
    }
    return registrations.values.first {
      $0.hasDocument && $0.window != nil
    }
  }

  /// First registration that is still a placeholder (no document
  /// bound yet). Used to redirect newTab / replaceCurrent dispatches
  /// at the launch placeholder rather than tabbing onto it.
  private func frontmostPlaceholderRegistration() -> WindowRegistration? {
    registrations.values.first {
      !$0.hasDocument && $0.window != nil
    }
  }

  /// True when at least one registered window already has a document
  /// bound. The launch placeholder uses this to decide whether to
  /// dismiss itself instead of running the FTUE open panel — if a
  /// real document window has appeared (from a URL dispatched out of
  /// `application(_:open:)` or anywhere else), the placeholder is
  /// redundant.
  func hasAnyDocumentWindow() -> Bool {
    registrations.values.contains {
      $0.hasDocument && $0.window != nil
    }
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
    let hadPending = !pending.isEmpty
    openHandler = handler
    let queue = pending
    pending.removeAll()
    for url in queue { handler(url) }
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

  /// Weak link to a `ContentView`'s `NSWindow` plus the closure that
  /// rebinds that window's WindowGroup binding + `DocumentModel` to a
  /// new URL. Closures live for the lifetime of the registration —
  /// they capture `self` from the enclosing view, so the registry
  /// must drop entries when the window goes away to avoid leaks.
  ///
  /// `currentURL` tracks the document the window is presently bound
  /// to. ContentView keeps it current via `updateCurrentURL` so
  /// `dispatch` can detect "this URL is already open" and route to
  /// the existing window instead of going through SwiftUI's
  /// `openWindow`, which no-ops for an already-bound URL value
  /// (and therefore wouldn't fire `.task(id:)` to consume a pending
  /// scroll line).
  private struct WindowRegistration {
    weak var window: NSWindow?
    let rebind: @MainActor (URL) -> Void
    var hasDocument: Bool
    var currentURL: URL?
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
