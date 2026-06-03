#if os(macOS)
//
//  ViewerTests.swift
//  Galley
//
//  Logic tests for the Viewer app. Uses `@testable import Galley` so
//  internal types (`ViewerOpenModel`, `HistorySnapshot`, `PerFileState`,
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

// No-op marker: the visionOS VisionWelcomeScreen icon swap is an asset/view
// change (Image asset + sizing) with no testable logic.

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

// MARK: - BindPlan

@Suite("BindPlan")
struct BindPlanTests {
  private let fileURL = URL(fileURLWithPath: "/tmp/binding.md")
  private let restoredURL = URL(fileURLWithPath: "/tmp/restored.md")

  /// Build a snapshot whose `currentURL` is `url`. Pre-encode it as
  /// JSON so tests pass it through `decide`'s `historyJSON` argument
  /// the way `@SceneStorage` would.
  private func snapshotJSON(currentURL: URL) -> HistorySnapshot {
    let snapshot = HistorySnapshot(
      urls: [currentURL], currentIndex: 0)
    return snapshot
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
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: false,
      history: nil,
      perFileState: uniformStore(PerFileState()))
    #expect(plan.action == .initialBind(
      target: DocumentTarget(url: fileURL), scrollY: nil,
      showsTOC: false))
    #expect(plan.zoom == 1.0)
    #expect(!plan.applyChoiceOverrides)
  }

  @Test("Cold launch: per-file zoom is propagated")
  func coldLaunchPropagatesZoom() {
    var stored = PerFileState()
    stored.pageZoom = 1.5
    let plan = BindPlan.decide(
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: false,
      history: nil,
      perFileState: uniformStore(stored))
    #expect(plan.zoom == 1.5)
  }

  @Test("Cold launch: per-file scrollY and showsTOC reach the action")
  func coldLaunchPropagatesScrollAndTOC() {
    var stored = PerFileState()
    stored.scrollY = 240.0
    stored.showsTOC = true
    let plan = BindPlan.decide(
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: false,
      history: nil,
      perFileState: uniformStore(stored))
    #expect(plan.action == .initialBind(
      target: DocumentTarget(url: fileURL), scrollY: 240.0,
      showsTOC: true))
  }

  // MARK: Restoration to the same URL

  /// Window restored at the same URL it was bound to — no override
  /// needed (the model was already constructed with that URL's
  /// per-file state).
  @Test("Restore to same URL: action=restore, no overrides")
  func restoreSameURL() {
    let plan = BindPlan.decide(
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: false,
      history: snapshotJSON(currentURL: fileURL),
      perFileState: uniformStore(PerFileState()))
    if case .restore(let snapshot, _, _) = plan.action {
      #expect(snapshot.currentURL == fileURL)
    } else {
      Issue.record("Expected .restore, got \(plan.action)")
    }
    #expect(!plan.applyChoiceOverrides)
  }

  // MARK: Restoration to a different URL — the override path

  /// Window's `WindowGroup<DocumentTarget>` binding resolved to one URL
  /// but state restoration brought back a different URL in the snapshot.
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
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: false,
      history: snapshotJSON(currentURL: restoredURL),
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
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: false,
      history: snapshotJSON(currentURL: restoredURL),
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
      target: DocumentTarget(url: fileURL),
      didFirstBind: true,
      didRestore: false,
      history: snapshotJSON(currentURL: restoredURL),
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
      target: DocumentTarget(url: fileURL),
      didFirstBind: true,
      didRestore: false,
      history: snapshotJSON(currentURL: restoredURL),
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
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: true,
      history: snapshotJSON(currentURL: restoredURL),
      perFileState: uniformStore(PerFileState()))
    // No restore action even though JSON exists; falls through to
    // initialBind on fileURL with no override.
    #expect(plan.action == .initialBind(
      target: DocumentTarget(url: fileURL), scrollY: nil,
      showsTOC: false))
    #expect(!plan.applyChoiceOverrides)
  }

  // MARK: Defensive — corrupt snapshot

  /// A snapshot whose `currentIndex` is out of range has nil
  /// `currentURL`. Treat as "no snapshot" — initialBind takes over.
  @Test("Snapshot with out-of-range index falls through to initialBind")
  func outOfRangeIndexFallsThrough() throws {
    let snapshot = HistorySnapshot(urls: [fileURL], currentIndex: 99)
    let plan = BindPlan.decide(
      target: DocumentTarget(url: fileURL),
      didFirstBind: false,
      didRestore: false,
      history: snapshot,
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
#endif
