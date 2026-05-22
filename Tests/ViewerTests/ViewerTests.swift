//
//  ViewerTests.swift
//  Galley
//
//  Logic tests for the Viewer app. Uses `@testable import Galley` so
//  internal types (`WindowDispatcher`, `HistorySnapshot`, `PerFileState`,
//  `EditorPreset`, etc.) are reachable from here. Pure-routing tests
//  for the kit live in `Tests/GalleyCoreKitTests/Routing/`.
//

import AppKit
import Foundation
import GalleyCoreKit
import Testing
@testable import Galley

@Test("Galley module loads")
func galleyModuleLoads() {
  #expect(Bool(true))
}

// MARK: - HistorySnapshot

@Suite("HistorySnapshot")
struct HistorySnapshotTests {
  private let urlA = URL(fileURLWithPath: "/tmp/a.md")
  private let urlB = URL(fileURLWithPath: "/tmp/b.md")
  private let urlC = URL(fileURLWithPath: "/tmp/c.md")

  @Test("currentURL returns the entry at currentIndex")
  func currentURLInBounds() {
    let snapshot = HistorySnapshot(
      urls: [urlA, urlB, urlC], currentIndex: 1)
    #expect(snapshot.currentURL == urlB)
  }

  @Test("currentURL returns nil when currentIndex is out of range")
  func currentURLOutOfBounds() {
    let high = HistorySnapshot(urls: [urlA], currentIndex: 5)
    let neg = HistorySnapshot(urls: [urlA], currentIndex: -1)
    let empty = HistorySnapshot(urls: [], currentIndex: 0)
    #expect(high.currentURL == nil)
    #expect(neg.currentURL == nil)
    #expect(empty.currentURL == nil)
  }

  /// `@SceneStorage` round-trips JSON-as-String. Pin the encode →
  /// decode round-trip so a Codable representation change can't
  /// silently break state restoration of all existing windows.
  @Test("Codable round-trip preserves urls and currentIndex")
  func codableRoundTrip() throws {
    let original = HistorySnapshot(
      urls: [urlA, urlB, urlC], currentIndex: 2)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      HistorySnapshot.self, from: data)
    #expect(decoded == original)
    #expect(decoded.urls == [urlA, urlB, urlC])
    #expect(decoded.currentIndex == 2)
  }

  /// Path with spaces — round-trip through JSON shouldn't lose
  /// encoding (it goes through `URL.absoluteString`).
  @Test("Codable round-trip preserves spaces in paths")
  func codableRoundTripSpaces() throws {
    let url = URL(fileURLWithPath: "/tmp/foo bar/baz qux.md")
    let original = HistorySnapshot(urls: [url], currentIndex: 0)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      HistorySnapshot.self, from: data)
    #expect(decoded.urls == [url])
  }

  @Test("Equatable is structural over urls and currentIndex")
  func equatable() {
    let snapA = HistorySnapshot(urls: [urlA, urlB], currentIndex: 1)
    let snapB = HistorySnapshot(urls: [urlA, urlB], currentIndex: 1)
    let snapC = HistorySnapshot(urls: [urlA, urlB], currentIndex: 0)
    let snapD = HistorySnapshot(urls: [urlA], currentIndex: 0)
    #expect(snapA == snapB)
    #expect(snapA != snapC)
    #expect(snapA != snapD)
  }

  /// Negative `currentIndex` is preserved in the encoded form so that
  /// `currentURL` can detect "corrupted store" rather than silently
  /// snapping to a fake value.
  @Test("Codable preserves out-of-range currentIndex")
  func codablePreservesNegativeIndex() throws {
    let original = HistorySnapshot(urls: [urlA], currentIndex: -1)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      HistorySnapshot.self, from: data)
    #expect(decoded.currentIndex == -1)
    #expect(decoded.currentURL == nil)
  }
}

// MARK: - PerFileState / PerFileStateStore

@Suite("PerFileState")
struct PerFileStateTests {
  @Test("Default state is empty (every field nil)")
  func defaultIsEmpty() {
    let state = PerFileState()
    #expect(state.isEmpty)
    #expect(state.pageZoom == nil)
    #expect(state.scrollY == nil)
    #expect(state.rendererPersistent == nil)
    #expect(state.templatePersistent == nil)
    #expect(state.showsTOC == nil)
  }

  @Test("isEmpty flips to false when any field is populated")
  func isEmptyFlipsOnAnyField() {
    var state = PerFileState()
    state.pageZoom = 1.25
    #expect(!state.isEmpty)

    state = PerFileState()
    state.scrollY = 42.0
    #expect(!state.isEmpty)

    state = PerFileState()
    state.rendererPersistent = "swift-markdown"
    #expect(!state.isEmpty)

    state = PerFileState()
    state.templatePersistent = "github"
    #expect(!state.isEmpty)

    state = PerFileState()
    state.showsTOC = false
    #expect(!state.isEmpty)
  }

  /// Pin Codable round-trip — the dict that contains these is
  /// persisted to disk via plist defaults, and a Codable shape change
  /// would break every previously-stored entry. Also verifies that
  /// `nil` fields stay `nil` after decoding (no silent default).
  @Test("Codable round-trip preserves all-nil fields")
  func codableRoundTripEmpty() throws {
    let original = PerFileState()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      PerFileState.self, from: data)
    #expect(decoded == original)
    #expect(decoded.isEmpty)
  }

  @Test("Codable round-trip preserves mixed populated fields")
  func codableRoundTripMixed() throws {
    var original = PerFileState()
    original.pageZoom = 1.5
    original.scrollY = 240.5
    original.showsTOC = true
    original.rendererPersistent = "pandoc"

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      PerFileState.self, from: data)
    #expect(decoded == original)
  }
}

@Suite("PerFileState dict subscript")
struct PerFileStateDictTests {
  /// The `[URL]` subscript routes through `PerFileState.key(for:)`
  /// which uses `URL.safe.path()`. Two URLs that differ only in
  /// percent-encoding of spaces should hit the same slot — the
  /// production store is keyed by the resolved file path, not the
  /// surface URL the WindowGroup binding hands us.
  @Test("Different URL surface forms (spaces) hit the same slot")
  func sameSlotAcrossEncoding() {
    var dict: [String: PerFileState] = [:]
    let viaPath = URL(fileURLWithPath: "/tmp/foo bar.md")
    let viaString = URL(string: "file:///tmp/foo%20bar.md")!
    dict[viaPath].pageZoom = 1.5
    #expect(dict[viaString].pageZoom == 1.5)
  }

  @Test("Distinct URLs are distinct slots")
  func distinctURLsAreDistinct() {
    var dict: [String: PerFileState] = [:]
    let urlA = URL(fileURLWithPath: "/tmp/a.md")
    let urlB = URL(fileURLWithPath: "/tmp/b.md")
    dict[urlA].pageZoom = 1.0
    dict[urlB].pageZoom = 2.0
    #expect(dict[urlA].pageZoom == 1.0)
    #expect(dict[urlB].pageZoom == 2.0)
  }

  @Test("Reading a never-written URL returns the empty default")
  func readMissingURL() {
    let dict: [String: PerFileState] = [:]
    let url = URL(fileURLWithPath: "/tmp/missing.md")
    #expect(dict[url].isEmpty)
  }

  @Test("Mutating one slot does not bleed into another")
  func slotsAreIndependent() {
    var dict: [String: PerFileState] = [:]
    let urlA = URL(fileURLWithPath: "/tmp/a.md")
    let urlB = URL(fileURLWithPath: "/tmp/b.md")
    dict[urlA].showsTOC = true
    #expect(dict[urlB].showsTOC == nil)
  }
}

// MARK: - EditorPreset / substituteEditorTemplate

@Suite("EditorPreset")
struct EditorPresetTests {
  /// Every preset's URL template must produce a parseable URL after
  /// substitution — otherwise cmd-click silently fails.
  @Test("Every preset produces a parseable URL with line",
        arguments: EditorPreset.urlTemplatePresets)
  func everyPresetParsesWithLine(preset: EditorPreset) {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let result = substituteEditorTemplate(
      preset.urlTemplate ?? "", fileURL: url, line: 42)
    #expect(URL(string: result) != nil, "\(preset) → \(result)")
    #expect(result.contains("42"), "\(preset) line missing: \(result)")
  }

  @Test("Every preset still parses when line is nil",
        arguments: EditorPreset.urlTemplatePresets)
  func everyPresetParsesWithoutLine(preset: EditorPreset) {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let result = substituteEditorTemplate(
      preset.urlTemplate ?? "", fileURL: url, line: nil)
    #expect(URL(string: result) != nil, "\(preset) → \(result)")
  }

  /// Paths with spaces must percent-encode in the resulting URL.
  /// Without encoding, `URL(string:)` returns nil and the editor
  /// open silently fails — exactly the bug class the tests exist to
  /// catch. The encoding form differs by placeholder:
  ///   - `{path}`: encodes the raw path → `foo%20bar`
  ///   - `{url}`:  encodes `absoluteString` (already has `%20`)
  ///              with query-allowed → `foo%2520bar`. The double
  ///              encoding is correct for URLs embedded as a query
  ///              parameter — the receiver decodes once for the
  ///              query and once for the URL.
  @Test("Spaces in path produce a parseable URL for every preset",
        arguments: EditorPreset.urlTemplatePresets)
  func spacesArePercentEncoded(preset: EditorPreset) {
    let url = URL(fileURLWithPath: "/tmp/foo bar/baz.md")
    let result = substituteEditorTemplate(
      preset.urlTemplate ?? "", fileURL: url, line: 1)
    #expect(URL(string: result) != nil, "\(preset) → \(result)")
    // The space MUST be encoded somehow — a literal space here means
    // the URL fails to parse on macOS 26 (older macOS versions were
    // lenient and accepted unencoded spaces, masking the bug).
    #expect(!result.contains("foo bar"), "\(preset) → \(result)")
    // Either single (%20) or double (%2520) encoding is acceptable
    // depending on placeholder; both decode back to a real space at
    // the receiving editor.
    #expect(
      result.contains("foo%20bar") || result.contains("foo%2520bar"),
      "\(preset) → \(result)")
  }

  /// Command-style presets (Xcode's `xed`) substitute `{path}` and
  /// `{line}` raw — no URL encoding — and `{line}` falls back to `"1"`
  /// so `--line {line}` always sees a valid integer.
  @Test("Every command preset substitutes path and line",
        arguments: EditorPreset.commandPresets)
  func everyCommandPresetSubstitutes(preset: EditorPreset) {
    guard case .command(_, let args) = preset.invocation else {
      Issue.record("\(preset) is not command-style")
      return
    }
    let url = URL(fileURLWithPath: "/tmp/foo bar/baz.md")
    let resolved = args.map {
      substituteCommandArg($0, fileURL: url, line: 42)
    }
    #expect(resolved.contains("/tmp/foo bar/baz.md"))
    #expect(resolved.contains("42"))
    #expect(!resolved.contains("{path}"))
    #expect(!resolved.contains("{line}"))
  }

  @Test("Command preset {line} defaults to 1 when caller passes nil")
  func commandLineDefault() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    #expect(
      substituteCommandArg("{line}", fileURL: url, line: nil) == "1")
  }

  @Test("Custom URL template substitutes all three placeholders")
  func customTemplateSubstitution() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let template = "myeditor:url={url}|path={path}|line={line}"
    let result = substituteEditorTemplate(
      template, fileURL: url, line: 7)
    #expect(result.contains("url=file:///tmp/note.md"))
    #expect(result.contains("path=/tmp/note.md"))
    #expect(result.contains("line=7"))
  }

  @Test("Empty line substitutes to empty string, not the literal")
  func emptyLine() {
    let url = URL(fileURLWithPath: "/tmp/note.md")
    let result = substituteEditorTemplate(
      "x://open?line={line}", fileURL: url, line: nil)
    #expect(result == "x://open?line=")
    #expect(!result.contains("{line}"))
  }
}

// MARK: - WindowDispatcher (no NSWindow paths)

/// Tests the dispatcher's launch-buffering, install-and-drain, and
/// "no windows registered" decisions. The NSWindow-touching code
/// paths (registerWindow / consumePendingTabHost / focusExisting
/// rebind) are exercised indirectly by the UITests in `UITests/`.
@MainActor
@Suite("WindowDispatcher")
struct WindowDispatcherTests {
  @Test("Pre-install URLs are buffered and replayed on install in order")
  func preInstallBuffering() {
    let dispatcher = WindowDispatcher()
    let urlA = URL(fileURLWithPath: "/tmp/a.md")
    let urlB = URL(fileURLWithPath: "/tmp/b.md")
    let urlC = URL(fileURLWithPath: "/tmp/c.md")
    dispatcher.handleOpenURLs([urlA, urlB])
    dispatcher.enqueueAtLaunch(urlC)
    var observed: [URL] = []
    dispatcher.install { observed.append($0) }
    #expect(observed == [urlA, urlB, urlC])
  }

  @Test("install returns true when there were pending URLs")
  func installReturnsHadPending() {
    let dispatcher = WindowDispatcher()
    dispatcher.enqueueAtLaunch(URL(fileURLWithPath: "/tmp/a.md"))
    let hadPending = dispatcher.install { _ in }
    #expect(hadPending)
  }

  @Test("install returns false when buffer is empty")
  func installReturnsFalseWhenEmpty() {
    let dispatcher = WindowDispatcher()
    let hadPending = dispatcher.install { _ in }
    #expect(!hadPending)
  }

  /// After install, subsequent `handleOpenURLs` calls go straight
  /// through to the openHandler (no buffering). With no registered
  /// windows, every URL spawns a new window — which means the
  /// openHandler fires once per URL.
  @Test("Post-install handleOpenURLs routes through openHandler")
  func postInstallRoutesThrough() {
    let dispatcher = WindowDispatcher()
    var observed: [URL] = []
    dispatcher.install { observed.append($0) }
    let url = URL(fileURLWithPath: "/tmp/note.md")
    dispatcher.handleOpenURLs([url])
    #expect(observed == [url])
  }

  /// `galley://path?line=N` must stash the scroll line *before* the
  /// dispatcher routes to the openHandler — otherwise the new
  /// window's `consumePendingScrollLine(for:)` returns nil and the
  /// editor's source-line jump silently fails on first open.
  @Test("galley://path?line=N stashes line before dispatch")
  func galleyURLStashesLine() {
    let dispatcher = WindowDispatcher()
    var observed: [URL] = []
    dispatcher.install { observed.append($0) }
    let inbound = URL(string: "galley:///tmp/note.md?line=42")!
    let expectedFile = URL(fileURLWithPath: "/tmp/note.md")
    dispatcher.handleOpenURLs([inbound])
    #expect(observed == [expectedFile])
    #expect(dispatcher.consumePendingScrollLine(for: expectedFile) == 42)
    // Idempotent — second consume returns nil.
    #expect(dispatcher.consumePendingScrollLine(for: expectedFile) == nil)
  }

  /// `galley://settings[?tab=N]` fans out to the
  /// `onSettingsRequested` callback rather than the openHandler.
  /// The handler must NOT see the URL, and the tab must reach the
  /// callback when present.
  @Test("Settings URLs route to the settings callback, not openHandler")
  func settingsRoutesAside() {
    let dispatcher = WindowDispatcher()
    var openHandlerSaw: [URL] = []
    var settingsSaw: [SettingsTab?] = []
    dispatcher.install { openHandlerSaw.append($0) }
    let url = URL(string: "galley://settings?tab=server")!
    dispatcher.handleOpenURLs([url]) { settingsSaw.append($0) }
    #expect(openHandlerSaw.isEmpty)
    #expect(settingsSaw == [.server])
  }

  /// Mixed batch: settings + document + bare-galley document. All
  /// three flow correctly — settings to the callback, both docs to
  /// the openHandler, with the line stashed for the one that had it.
  @Test("Mixed batch: settings + doc + galley doc are routed correctly")
  func mixedBatch() {
    let dispatcher = WindowDispatcher()
    var openHandlerSaw: [URL] = []
    var settingsSaw: [SettingsTab?] = []
    dispatcher.install { openHandlerSaw.append($0) }
    let settings = URL(string: "galley://settings")!
    let doc = URL(fileURLWithPath: "/tmp/doc.md")
    let galleyDoc = URL(string: "galley:///tmp/note.md?line=7")!
    let expectedNote = URL(fileURLWithPath: "/tmp/note.md")
    dispatcher.handleOpenURLs([settings, doc, galleyDoc]) {
      settingsSaw.append($0)
    }
    #expect(settingsSaw == [nil])
    #expect(openHandlerSaw == [doc, expectedNote])
    #expect(dispatcher.consumePendingScrollLine(for: expectedNote) == 7)
  }

  /// `hasAnyDocumentWindow` reflects the live registry, not the
  /// pre-launch buffer. Pre-install handling shouldn't make the
  /// dispatcher think a window exists.
  @Test("hasAnyDocumentWindow is false for a fresh dispatcher")
  func hasAnyFalseInitially() {
    let dispatcher = WindowDispatcher()
    #expect(!dispatcher.hasAnyDocumentWindow())
    dispatcher.enqueueAtLaunch(URL(fileURLWithPath: "/tmp/a.md"))
    #expect(!dispatcher.hasAnyDocumentWindow())
    dispatcher.install { _ in }
    #expect(!dispatcher.hasAnyDocumentWindow())
  }

  /// `consumePendingTabHost` returns nil when nothing has been
  /// queued. The production caller (`WindowAccessor.onAttach`) is
  /// safe to call this unconditionally on every window attach.
  @Test("consumePendingTabHost returns nil on a fresh dispatcher")
  func consumePendingTabHostEmpty() {
    let dispatcher = WindowDispatcher()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    #expect(dispatcher.consumePendingTabHost(for: url) == nil)
  }

  /// Unparseable URLs (galley:// with no path, no host) should still
  /// reach the openHandler — the production code's policy is "log
  /// and pass through" so the user isn't silently stranded.
  @Test("Unparseable URLs pass through to openHandler")
  func unparseablePassesThrough() {
    let dispatcher = WindowDispatcher()
    var observed: [URL] = []
    dispatcher.install { observed.append($0) }
    let weird = URL(string: "galley://")!
    dispatcher.handleOpenURLs([weird])
    #expect(observed == [weird])
  }
}

// MARK: - WindowDispatcher.adopt (NSWindow-touching paths)

/// Tests for the multi-step `adopt(_:fileURL:didFirstBind:rebind:)`
/// ceremony. Constructs real `NSWindow` instances — cheap, hosted by
/// the Tests target's `Galley.app` so AppKit is fully alive.
@MainActor
@Suite("WindowDispatcher.adopt")
struct WindowDispatcherAdoptTests {
  /// Build an off-screen, undecorated window we can safely inspect
  /// without touching the user's screen. The dispatcher's adopt
  /// ceremony only reads `alphaValue`, `isVisible`, and registers
  /// the window — none of those need the window to be on screen.
  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    return window
  }

  // MARK: Reveal alpha

  @Test("adopt with didFirstBind=false leaves alphaValue at 0")
  func adoptKeepsHiddenWhenNotBound() {
    let dispatcher = WindowDispatcher()
    let window = makeWindow()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    dispatcher.adopt(
      window, fileURL: url, didFirstBind: false) { _ in }
    #expect(window.alphaValue == 0)
  }

  @Test("adopt with didFirstBind=true reveals the window")
  func adoptRevealsWhenBound() {
    let dispatcher = WindowDispatcher()
    let window = makeWindow()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    dispatcher.adopt(
      window, fileURL: url, didFirstBind: true) { _ in }
    #expect(window.alphaValue == 1)
  }

  // MARK: Registry effects

  @Test("adopt registers the window in the routing registry")
  func adoptRegisters() {
    let dispatcher = WindowDispatcher()
    #expect(!dispatcher.hasAnyDocumentWindow())
    let window = makeWindow()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    dispatcher.adopt(
      window, fileURL: url, didFirstBind: true) { _ in }
    #expect(dispatcher.hasAnyDocumentWindow())
  }

  /// After adopt, the dispatcher must be able to drive the window's
  /// rebind closure for `replaceCurrent` and `focusExisting` paths.
  /// The rebind closure is the callback the routing layer invokes
  /// when a new URL should replace the contents of an existing
  /// window — testing it pinned here rather than only via XCUITest.
  @Test("adopt's rebind closure is invoked on replaceCurrent dispatch")
  func adoptedRebindCalledOnReplace() {
    let dispatcher = WindowDispatcher()
    var openHandlerCalls: [URL] = []
    dispatcher.install { openHandlerCalls.append($0) }

    let window = makeWindow()
    let initialURL = URL(fileURLWithPath: "/tmp/initial.md")
    var rebindCalls: [URL] = []
    dispatcher.adopt(
      window, fileURL: initialURL, didFirstBind: true
    ) { newURL in
      rebindCalls.append(newURL)
    }

    // The window is registered; a same-URL re-dispatch must take
    // the focusExisting path, which calls the rebind closure (the
    // closure detects same-URL internally and just scrolls).
    dispatcher.handleOpenURLs([initialURL])

    // The router returns .focusExisting → openHandler is NOT
    // invoked (no new window spawn) and rebind IS invoked.
    #expect(openHandlerCalls.isEmpty)
    #expect(rebindCalls == [initialURL])
  }

  // MARK: Tab-host consumption

  /// When a `newTab` open queues a host for this URL, adopt must
  /// drain the queue entry. The `host.isVisible` gate inside adopt
  /// can keep the actual `addTabbedWindow` from running in tests
  /// (off-screen windows aren't visible), but the queue entry MUST
  /// be consumed regardless — otherwise it lingers and poisons a
  /// later legitimate open of the same URL.
  @Test("adopt consumes the queued tab host for fileURL")
  func adoptConsumesQueuedTabHost() {
    let dispatcher = WindowDispatcher()
    dispatcher.install { _ in }
    let host = makeWindow()
    let url = URL(fileURLWithPath: "/tmp/note.md")
    // Queue a tab-host entry for `url` via the public API.
    dispatcher.openAsTabs([url], onto: host)
    // Sanity: the entry is queued.
    // (We can't peek without consume — instead, verify a future
    // adopt drains it by checking `consumePendingTabHost` after.)
    let newWindow = makeWindow()
    dispatcher.adopt(
      newWindow, fileURL: url, didFirstBind: true) { _ in }
    // Now the queue is empty for that URL — a second consume is nil.
    #expect(dispatcher.consumePendingTabHost(for: url) == nil)
  }

  /// adopt for an unrelated URL must NOT consume queued entries for
  /// other URLs — the URL-keyed queue is robust against fan-out
  /// dedup of `openWindow(value:)` per the dispatcher's contract.
  @Test("adopt does not consume entries for other URLs")
  func adoptDoesNotConsumeOtherURLs() {
    let dispatcher = WindowDispatcher()
    dispatcher.install { _ in }
    let host = makeWindow()
    let urlA = URL(fileURLWithPath: "/tmp/a.md")
    let urlB = URL(fileURLWithPath: "/tmp/b.md")
    dispatcher.openAsTabs([urlA], onto: host)

    let unrelated = makeWindow()
    dispatcher.adopt(
      unrelated, fileURL: urlB, didFirstBind: true) { _ in }
    // The A entry is still there.
    #expect(dispatcher.consumePendingTabHost(for: urlA) === host)
  }

  // MARK: Detach symmetry

  /// `unregisterWindow` is the documented detach-side counterpart.
  /// Verify the round-trip leaves the registry empty so SwiftUI's
  /// re-attach (close + reopen the same URL) starts fresh.
  @Test("adopt + unregisterWindow round-trip leaves registry empty")
  func adoptUnregisterRoundTrip() {
    let dispatcher = WindowDispatcher()
    let window = makeWindow()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    dispatcher.adopt(
      window, fileURL: url, didFirstBind: true) { _ in }
    #expect(dispatcher.hasAnyDocumentWindow())
    dispatcher.unregisterWindow(window)
    #expect(!dispatcher.hasAnyDocumentWindow())
  }

  /// Belt-and-suspenders: `unregisterWindow` is also called by the
  /// `willCloseNotification` observer installed inside register. A
  /// double-unregister must be safe — covered indirectly by
  /// `WindowRegistry`'s "unregister of unknown id is a no-op" test
  /// in the routing suite, but pinned here at the dispatcher level
  /// for the AppKit-bridged path.
  @Test("Double unregisterWindow is safe")
  func doubleUnregisterIsSafe() {
    let dispatcher = WindowDispatcher()
    let window = makeWindow()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    dispatcher.adopt(
      window, fileURL: url, didFirstBind: true) { _ in }
    dispatcher.unregisterWindow(window)
    dispatcher.unregisterWindow(window)
    #expect(!dispatcher.hasAnyDocumentWindow())
  }

  // MARK: Re-attach to a different NSWindow for the same URL

  /// SwiftUI re-uses scene `@State` when a window is closed and the
  /// same URL is reopened — `WindowAccessor.onAttach` then runs again
  /// with a fresh `NSWindow`. The dispatcher must be able to adopt
  /// the new window without tripping over the stale registration.
  /// (DocumentView's identity guard already filters no-op re-fires;
  /// this test pins the dispatcher's tolerance for the legitimate
  /// case where an old window was unregistered and a new one is
  /// being adopted for the same URL.)
  @Test("Re-adopt for same URL with a fresh NSWindow works")
  func reAdoptForSameURL() {
    let dispatcher = WindowDispatcher()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    let first = makeWindow()
    dispatcher.adopt(
      first, fileURL: url, didFirstBind: true) { _ in }
    dispatcher.unregisterWindow(first)
    let second = makeWindow()
    dispatcher.adopt(
      second, fileURL: url, didFirstBind: true) { _ in }
    #expect(dispatcher.hasAnyDocumentWindow())
  }
}

// MARK: - HistorySnapshot JSON adapter

@Suite("HistorySnapshot JSON adapter")
struct HistorySnapshotJSONTests {
  private let urlA = URL(fileURLWithPath: "/tmp/a.md")
  private let urlB = URL(fileURLWithPath: "/tmp/b.md")

  @Test("encode → decode round-trips through a String")
  func roundTripString() throws {
    let original = HistorySnapshot(
      urls: [urlA, urlB], currentIndex: 1)
    let encoded = try #require(original.encodedAsJSON())
    let decoded = try #require(HistorySnapshot.decode(json: encoded))
    #expect(decoded == original)
  }

  /// `@SceneStorage` initial state is `""`. The decode adapter must
  /// treat that as "no snapshot" — the production caller's launch
  /// path branches on nil here.
  @Test("Empty string decodes to nil")
  func emptyStringIsNil() {
    #expect(HistorySnapshot.decode(json: "") == nil)
  }

  /// Defensive: malformed JSON (corrupt store, schema mismatch) must
  /// not crash. The launch path falls back to a fresh bind on nil.
  @Test("Malformed JSON decodes to nil")
  func malformedJSONIsNil() {
    #expect(HistorySnapshot.decode(json: "{") == nil)
    #expect(HistorySnapshot.decode(json: "not-json") == nil)
    #expect(HistorySnapshot.decode(json: "[1,2,3]") == nil)
  }

  /// A snapshot with empty `urls` is semantically equivalent to "no
  /// snapshot" — pin that the decoder treats it as nil so the
  /// initial-bind path runs in the launchTask interpreter.
  @Test("Decode of {urls: [], currentIndex: 0} returns nil")
  func emptyURLsIsNil() throws {
    let empty = HistorySnapshot(urls: [], currentIndex: 0)
    let json = try #require(empty.encodedAsJSON())
    #expect(HistorySnapshot.decode(json: json) == nil)
  }

  /// Out-of-range `currentIndex` is preserved on decode (it's the
  /// caller's job to detect via `currentURL`). This pins the contract
  /// that the JSON adapter is dumb storage — it doesn't normalize.
  @Test("Decode preserves out-of-range currentIndex")
  func decodePreservesNegativeIndex() throws {
    let original = HistorySnapshot(urls: [urlA], currentIndex: -1)
    let encoded = try #require(original.encodedAsJSON())
    let decoded = try #require(HistorySnapshot.decode(json: encoded))
    #expect(decoded.currentIndex == -1)
    #expect(decoded.currentURL == nil)
  }
}

// MARK: - BindPlan

@Suite("BindPlan")
struct BindPlanTests {
  private let fileURL = URL(fileURLWithPath: "/tmp/binding.md")
  private let restoredURL = URL(fileURLWithPath: "/tmp/restored.md")

  /// Build a snapshot whose `currentURL` is `url`. Pre-encode it as
  /// JSON so tests pass it through `decide`'s `historyJSON` argument
  /// the way `@SceneStorage` would.
  private func snapshotJSON(currentURL: URL) -> String {
    let snapshot = HistorySnapshot(
      urls: [currentURL], currentIndex: 0)
    return snapshot.encodedAsJSON() ?? ""
  }

  /// Build a perFileState lookup that returns `state` for any URL —
  /// useful when the test doesn't need URL-discrimination.
  private func uniformStore(_ state: PerFileState) -> (URL) -> PerFileState {
    { _ in state }
  }

  // MARK: Cold launch — no snapshot, fresh window

  @Test("Cold launch: no snapshot → initialBind for fileURL")
  func coldLaunchInitialBind() {
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: "",
      perFileState: uniformStore(PerFileState()))
    #expect(plan.action == .initialBind(
      url: fileURL, scrollY: nil, showsTOC: false))
    #expect(plan.zoom == 1.0)
    #expect(!plan.applyChoiceOverrides)
  }

  @Test("Cold launch: per-file zoom is propagated")
  func coldLaunchPropagatesZoom() {
    var stored = PerFileState()
    stored.pageZoom = 1.5
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: "",
      perFileState: uniformStore(stored))
    #expect(plan.zoom == 1.5)
  }

  @Test("Cold launch: per-file scrollY and showsTOC reach the action")
  func coldLaunchPropagatesScrollAndTOC() {
    var stored = PerFileState()
    stored.scrollY = 240.0
    stored.showsTOC = true
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: "",
      perFileState: uniformStore(stored))
    #expect(plan.action == .initialBind(
      url: fileURL, scrollY: 240.0, showsTOC: true))
  }

  // MARK: Restoration to the same URL

  /// Window restored at the same URL it was bound to — no override
  /// needed (the model was already constructed with that URL's
  /// per-file state).
  @Test("Restore to same URL: action=restore, no overrides")
  func restoreSameURL() {
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: snapshotJSON(currentURL: fileURL),
      perFileState: uniformStore(PerFileState()))
    if case .restore(let snapshot, _, _) = plan.action {
      #expect(snapshot.currentURL == fileURL)
    } else {
      Issue.record("Expected .restore, got \(plan.action)")
    }
    #expect(!plan.applyChoiceOverrides)
  }

  // MARK: Restoration to a different URL — the override path

  /// Window's `WindowGroup<URL>` binding resolved to one URL but
  /// state restoration brought back a different URL in the snapshot.
  /// The interpreter must override the per-window choice envelopes
  /// — this is the bug class the BindPlan extraction makes testable.
  @Test("Restore to different URL: applyChoiceOverrides = true")
  func restoreDifferentURLOverrides() {
    var restoredState = PerFileState()
    restoredState.templatePersistent = "github"
    restoredState.rendererPersistent = "pandoc"
    let store: (URL) -> PerFileState = { url in
      url == self.restoredURL ? restoredState : PerFileState()
    }
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: snapshotJSON(currentURL: restoredURL),
      perFileState: store)
    #expect(plan.applyChoiceOverrides)
    #expect(plan.templateOverride == "github")
    #expect(plan.rendererOverride == "pandoc")
  }

  /// The store lookup keys off the *restored* URL, not the binding —
  /// the entire point of the override path is that the binding's
  /// per-file state is the wrong one.
  @Test("Restore to different URL: store lookup keys off restored URL")
  func restoreUsesRestoredStore() {
    var restoredState = PerFileState()
    restoredState.scrollY = 999.0
    restoredState.pageZoom = 2.0
    let store: (URL) -> PerFileState = { url in
      url == self.restoredURL ? restoredState : PerFileState()
    }
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: snapshotJSON(currentURL: restoredURL),
      perFileState: store)
    #expect(plan.zoom == 2.0)
    if case .restore(_, let scrollY, _) = plan.action {
      #expect(scrollY == 999.0)
    } else {
      Issue.record("Expected .restore, got \(plan.action)")
    }
  }

  // MARK: didFirstBind short-circuit

  /// Re-fire of `.task` after the model has bound: action becomes
  /// `alreadyBound` regardless of whether a snapshot exists. The
  /// interpreter still applies zoom and overrides.
  @Test("didFirstBind=true: action is alreadyBound")
  func didFirstBindShortCircuits() {
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: true,
      didRestore: false,
      historyJSON: snapshotJSON(currentURL: restoredURL),
      perFileState: uniformStore(PerFileState()))
    #expect(plan.action == .alreadyBound)
  }

  /// Even when alreadyBound, applyChoiceOverrides + zoom still
  /// reflect the snapshot's URL (so a re-fire of .task after a
  /// state-restored window doesn't strand the overrides as nil).
  @Test("alreadyBound + restored-different-URL: overrides still computed")
  func alreadyBoundStillComputesOverrides() {
    var restoredState = PerFileState()
    restoredState.templatePersistent = "github"
    restoredState.pageZoom = 1.5
    let store: (URL) -> PerFileState = { url in
      url == self.restoredURL ? restoredState : PerFileState()
    }
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: true,
      didRestore: false,
      historyJSON: snapshotJSON(currentURL: restoredURL),
      perFileState: store)
    #expect(plan.action == .alreadyBound)
    #expect(plan.applyChoiceOverrides)
    #expect(plan.templateOverride == "github")
    #expect(plan.zoom == 1.5)
  }

  // MARK: didRestore gates snapshot decoding

  /// After a successful restore, `didRestore=true` is set so a
  /// subsequent `.task` re-fire doesn't re-enter restore. The
  /// snapshot is *not* decoded on those fires — pin that.
  @Test("didRestore=true: snapshot is ignored")
  func didRestoreGatesSnapshotDecode() {
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: true,
      historyJSON: snapshotJSON(currentURL: restoredURL),
      perFileState: uniformStore(PerFileState()))
    // No restore action even though JSON exists; falls through to
    // initialBind on fileURL with no override.
    #expect(plan.action == .initialBind(
      url: fileURL, scrollY: nil, showsTOC: false))
    #expect(!plan.applyChoiceOverrides)
  }

  // MARK: Defensive — corrupt snapshot

  /// Corrupt JSON in `@SceneStorage` falls through to initialBind
  /// rather than crashing. The end-to-end equivalent (corrupt store
  /// at relaunch) is hard to drive from XCUITest; here it's one
  /// assertion.
  @Test("Corrupt historyJSON falls through to initialBind")
  func corruptSnapshotFallsThrough() {
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: "{this is not valid json",
      perFileState: uniformStore(PerFileState()))
    #expect(plan.action == .initialBind(
      url: fileURL, scrollY: nil, showsTOC: false))
  }

  /// A snapshot whose `currentIndex` is out of range has nil
  /// `currentURL`. Treat as "no snapshot" — initialBind takes over.
  @Test("Snapshot with out-of-range index falls through to initialBind")
  func outOfRangeIndexFallsThrough() throws {
    let snapshot = HistorySnapshot(urls: [fileURL], currentIndex: 99)
    let json = try #require(snapshot.encodedAsJSON())
    let plan = BindPlan.decide(
      fileURL: fileURL,
      didFirstBind: false,
      didRestore: false,
      historyJSON: json,
      perFileState: uniformStore(PerFileState()))
    // Snapshot decodes successfully (urls is non-empty), so the
    // restore branch fires — but `currentURL` is nil, so the
    // override path doesn't trigger. The interpreter's
    // `model.restore` call will itself reject the snapshot
    // (currentIndex bounds-check) and short-circuit.
    if case .restore(let snap, _, _) = plan.action {
      #expect(snap.currentURL == nil)
    } else {
      Issue.record("Expected .restore, got \(plan.action)")
    }
    #expect(!plan.applyChoiceOverrides)
  }
}

// MARK: - DocumentStats

@Suite("DocumentStats")
struct DocumentStatsTests {
  @Test("readingTime is wordCount / wordsPerMinute, in seconds")
  func readingTimeArithmetic() {
    let stats = DocumentStats(
      wordCount: 400, characterCount: 2000, headingCount: 8)
    #expect(stats.readingTime(wordsPerMinute: 200) == 120)
    #expect(stats.readingTime(wordsPerMinute: 100) == 240)
  }

  @Test("readingTime is zero for an empty document")
  func readingTimeEmpty() {
    #expect(DocumentStats.empty.readingTime(wordsPerMinute: 200) == 0)
  }

  @Test("readingTime is zero for a non-positive WPM")
  func readingTimeNonPositiveWPM() {
    let stats = DocumentStats(
      wordCount: 400, characterCount: 2000, headingCount: 8)
    #expect(stats.readingTime(wordsPerMinute: 0) == 0)
    #expect(stats.readingTime(wordsPerMinute: -100) == 0)
  }
}
