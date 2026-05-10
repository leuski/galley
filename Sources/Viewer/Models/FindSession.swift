import Foundation
import Observation
import WebKit

/// Per-window find-text session — owns the query, options, match
/// counters, and the visibility / dismissal flags driven by the
/// surrounding find UI. Lives on `DocumentModel.find` and is reissued
/// at window construction; not persisted across launches (the find
/// bar reopens empty, matching Preview / Safari).
///
/// JS calls go through the host `WebPage`. `clearHighlights` and the
/// search / next / prev calls are no-ops while the page is between
/// renders or before `window.galleyFind` binds — `FindBridge`'s user
/// script wires it in at `documentEnd` of every load.
@Observable
@MainActor
final class FindSession: SearchModel {
  @ObservationIgnored private let page: WebPage

  /// Whether the find-text bar is showing in the host window.
  /// Per-document; not persisted across launches.
  var isVisible: Bool = false

  /// Live find query. `SearchField`'s `.onChange` triggers an
  /// immediate `performSearch`.
  var query: String = ""

  /// Number of matches found by the latest `performSearch`. Drives
  /// the "n of N" count in the find bar.
  var matchCount: Int = 0

  /// Zero-based index of the currently-highlighted match, or `-1`
  /// when there is nothing highlighted (empty query / no matches).
  var matchIndex: Int = -1

  /// When true, find matches ignore case. Defaults true to match
  /// Preview / Safari — most users expect case-insensitive find.
  var ignoresCase: Bool = true

  /// When true, find only matches whole words (regex `\b…\b`).
  /// ASCII-boundary based — sufficient for the Latin-script content
  /// the viewer most often renders.
  var wholeWord: Bool = false

  /// Monotonic token bumped when an external surface (toolbar
  /// `Action.toggleFind`, View menu) requests the find bar to dismiss.
  /// `FindBar` observes this so it can drop focus before the slide-out
  /// transition starts — otherwise the focus ring renders over content
  /// the bar slides past. Direct `hide()` is the unanimated path;
  /// this token is the animated, focus-aware path.
  var dismissalToken: Int = 0

  init(page: WebPage) {
    self.page = page
  }

  /// Ask the find bar to dismiss with focus-aware timing — used by
  /// surfaces (toolbar, View menu) that don't own the `@FocusState`.
  /// `FindBar` observes the token, drops focus, then animates the
  /// hide so the focus ring isn't drawn over content as the bar
  /// slides away.
  func requestFindDismissal() {
    dismissalToken &+= 1
  }

  func toggleFind(reduceMotion: Bool) {
    if isVisible {
      // Routed through the dismissal token so `FindBar` can drop
      // focus before the slide-out transition begins.
      requestFindDismissal()
    } else {
      withAnimationAsNeeded(reduceMotion) { isVisible = true }
    }
  }

  /// macOS-standard "Use Selection for Find" (⌘E). Reads the WebView's
  /// current text selection, drops it into `query`, reveals the bar,
  /// and runs the search. Falls back to plain reveal when the
  /// selection is empty or the JS read throws.
  func useSelectionForFind(reduceMotion: Bool) async {
    let selection = await currentSelection()
    let trimmed = selection.trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      withAnimationAsNeeded(reduceMotion) { isVisible = true }
      return
    }
    query = trimmed
    withAnimationAsNeeded(reduceMotion) { isVisible = true }
    // The bar's `.onChange(of: query)` is wired only once the
    // view mounts, so the synchronous assignment above wouldn't
    // trigger it on first reveal — drive the search explicitly.
    await performSearch()
  }

  private func currentSelection() async -> String {
    do {
      let value = try await page.callJavaScript(
        "return window.getSelection().toString();")
      return (value as? String) ?? ""
    } catch {
      return ""
    }
  }

  /// Hide the find bar and clear any in-page highlights. Leaves
  /// `query` intact so re-opening with ⌘F restores the last query —
  /// matches Safari / Preview behavior.
  ///
  /// Synchronous so call sites can wrap the visibility flip in
  /// `withAnimation { ... }`. JS highlight teardown is fire-and-forget
  /// — observers don't care about its completion and it would block
  /// the animation otherwise.
  func hide() {
    isVisible = false
    matchCount = 0
    matchIndex = -1
    Task { await clearHighlights() }
  }

  /// Run the current `query` against the rendered DOM. Empty
  /// queries clear highlights and reset the counters.
  func performSearch() async {
    let trimmed = query
    guard !trimmed.isEmpty else {
      await clearHighlights()
      matchCount = 0
      matchIndex = -1
      return
    }
    let escaped = jsStringLiteral(trimmed)
    let caseFlag = ignoresCase ? "false" : "true"
    let wholeFlag = wholeWord ? "true" : "false"
    let script = """
      var r = window.galleyFind.search(\(escaped), \(caseFlag), \(wholeFlag));
      return [r.count, r.index];
      """
    do {
      let value = try await page.callJavaScript(script)
      let (count, index) = decodeFindResult(value)
      matchCount = count
      matchIndex = index
    } catch {
      matchCount = 0
      matchIndex = -1
    }
  }

  /// Cycle to the next match. No-op if there are no matches.
  func findNext() async {
    guard matchCount > 0 else { return }
    do {
      let value = try await page.callJavaScript(
        "return window.galleyFind.next();")
      matchIndex = decodeIntScalar(value) ?? matchIndex
    } catch {
      // Leave index unchanged on JS error — UI stays consistent.
    }
  }

  /// Cycle to the previous match. No-op if there are no matches.
  func findPrevious() async {
    guard matchCount > 0 else { return }
    do {
      let value = try await page.callJavaScript(
        "return window.galleyFind.prev();")
      matchIndex = decodeIntScalar(value) ?? matchIndex
    } catch {
      // Leave index unchanged on JS error — UI stays consistent.
    }
  }

  /// Re-run the active query against the freshly-rebuilt DOM. Called
  /// by `DocumentModel` after every render so highlights and counts
  /// come back without user action across file-watcher reloads.
  func reapplyIfActive() async {
    guard isVisible, !query.isEmpty else { return }
    await performSearch()
  }

  /// Tear down any `<mark>` wrappers the controller has installed.
  /// Safe to call even when no search has run; the JS side no-ops on
  /// an empty marks list.
  private func clearHighlights() async {
    _ = try? await page.callJavaScript(
      "if (window.galleyFind) window.galleyFind.clear();")
  }

  /// Decode `[count, index]` returned by the JS side. Defensive — JS
  /// can hand back numbers as `Int`, `Double`, or `NSNumber` depending
  /// on bridging path.
  private func decodeFindResult(_ value: Any?) -> (Int, Int) {
    guard let array = value as? [Any], array.count == 2 else {
      return (0, -1)
    }
    let count = decodeIntScalar(array[0]) ?? 0
    let index = decodeIntScalar(array[1]) ?? -1
    return (count, index)
  }

  private func decodeIntScalar(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }
}
