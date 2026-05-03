import AppKit
import GalleyCoreKit
import Observation
import os
import SwiftUI
import UniformTypeIdentifiers

/// Thin AppKit bridge for the few hooks SwiftUI doesn't yet
/// natively cover. Routing/registry state has moved out to
/// `WindowDispatcher` and recent-document state to
/// `RecentDocumentsModel`; the delegate's only remaining
/// responsibility is forwarding `application(_:open:)` callbacks to
/// the dispatcher and exposing the FTUE Open panel runner.
///
/// Why does this still exist?
///   - `application(_:open:)` is the only reliable entry point for
///     Finder/LaunchServices URL dispatches that arrive before any
///     SwiftUI view exists. (Once SwiftUI's `.onOpenURL` proves
///     reliable for our use case, we delete this file entirely.)
///   - `presentOpenPanel` runs an `NSOpenPanel` from the File menu;
///     it's invoked via the `FileCommands` Bindable wiring.
///   - State-restoration / terminate-after-last-window flags would
///     all be defaults if unimplemented, but we leave explicit
///     overrides for documentation.
@MainActor
@Observable
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
  /// Set by `ViewerApp.body` so `application(_:open:)` can route
  /// URLs through the same model the SwiftUI views use. The body
  /// runs after the AppDelegate is constructed by the
  /// `NSApplicationDelegateAdaptor`, so this is `nil` for a brief
  /// window at launch — early URLs are queued by the dispatcher
  /// itself once it becomes available.
  @ObservationIgnored weak var dispatcher: WindowDispatcher?

  /// Reference to the shared `AppModel`, set by `ViewerApp` so
  /// `application(_:open:)` (and Open Recent) consult `openBehavior`
  /// without a SwiftUI environment lookup.
  @ObservationIgnored weak var appModel: AppModel?

  /// Active FTUE open panel, kept so we can cancel it when an
  /// incoming document rebinds the placeholder out from under the
  /// launch picker.
  @ObservationIgnored private weak var activeOpenPanel: NSOpenPanel?

  /// Mirrors `NSDocumentController.shared.recentDocumentURLs`. Updated
  /// whenever we record or clear a recent URL. Bound from the File
  /// menu's Open Recent submenu.
  private(set) var recentURLs: [URL] = []

  /// Set true when AppKit signals launch is complete.
  private(set) var didFinishLaunching = false

  /// Parsed view of `CommandLine.arguments`. Tests pass injection
  /// flags (`--seed-file`); production launches pass none.
  @ObservationIgnored let launchArgs: LaunchArguments

  override init() {
    self.launchArgs = LaunchArguments.fromProcess()
    super.init()
    self.recentURLs = NSDocumentController.shared.recentDocumentURLs
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    // The dispatcher was wired by the App's body before launch
    // completed; pre-seed the buffer with any test-mode URL.
    if let seed = launchArgs.seedFile {
      dispatcher?.enqueueAtLaunch(seed)
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let dispatcher else { return }
    dispatcher.handleOpenURLs(urls) {
      // `galley://settings` is also handled by `.onOpenURL` on the
      // WindowGroup root view (which calls SwiftUI's
      // `openSettings()`); leave the closure empty here so we don't
      // double-fire the Settings window.
    }
    for url in urls {
      switch URLNormalizer.normalize(url) {
      case .openSettings:
        continue
      case .document(let fileURL, _):
        record(fileURL)
      case .unparseable(let original):
        record(original)
      }
    }
  }

  /// Returning false here is deliberate: the always-alive
  /// `Window("welcome")` scene defined in `ViewerApp` captures
  /// `openWindow` and hosts the FTUE Open panel. SwiftUI doesn't
  /// bridge `applicationShouldOpenUntitledFile` to value-driven
  /// `WindowGroup`s anyway.
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
    false
  }

  /// Opt in to secure state restoration so macOS persists the open
  /// windows (and SwiftUI persists their `@SceneStorage` payloads)
  /// across launches without warning about insecure coding.
  func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }

  /// Stay alive after the last window closes — the user can launch
  /// the open panel again from File > Open. (Default already, but
  /// leave explicit for documentation.)
  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  // MARK: - File menu / Open Recent

  /// Open one or more files via NSOpenPanel and dispatch them
  /// through the same routing path as Finder opens.
  func presentOpenPanel() {
    Task { application(NSApp, open: await runOpenPanel()) }
  }

  /// Run NSOpenPanel and return the picked URLs without dispatching
  /// anywhere. Used by the welcome FTUE flow so the caller can
  /// route the picks itself.
  ///
  /// Uses the async `begin` form rather than `runModal` because
  /// `runModal` cannot start inside a SwiftUI/CoreAnimation
  /// transaction commit.
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

  /// Open a single previously-opened URL through the same dispatch
  /// path as Finder/NSOpenPanel — used by the Open Recent menu.
  func openRecent(_ url: URL) {
    application(NSApp, open: [url])
  }

  /// Record a URL as recently opened.
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
