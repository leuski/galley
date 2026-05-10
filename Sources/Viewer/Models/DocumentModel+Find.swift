//
//  DocumentModel+Find.swift
//  Galley
//
//  Created by Anton Leuski on 5/8/26.
//

import WebKit

/// `SearchField` conformance. The view talks to a generic
/// `SearchFieldModel`; `DocumentModel`'s find state already covers
/// every requirement, so this is a thin renaming layer over the
/// existing `find*` properties and `performFind()`.
extension DocumentModel: SearchModel {
  var query: String {
    get { findQuery }
    set { findQuery = newValue }
  }
  var ignoresCase: Bool {
    get { !findCaseSensitive }
    set { findCaseSensitive = !newValue }
  }
  var wholeWord: Bool {
    get { findWholeWord }
    set { findWholeWord = newValue }
  }
  var matchCount: Int { findMatchCount }
  var matchIndex: Int { findMatchIndex }
  func performSearch() async { await performFind() }
}

extension DocumentModel {

  /// Ask the find bar to dismiss with focus-aware timing — used by
  /// surfaces (toolbar, View menu) that don't own the `@FocusState`.
  /// `FindBar` observes the token, drops focus, then animates the
  /// hide so the focus ring isn't drawn over content as the bar
  /// slides away.
  func requestFindDismissal() {
    findDismissalToken &+= 1
  }

  func toggleFind(reduceMotion: Bool) {
    if isFindVisible {
      // Routed through the dismissal token so `FindBar` can drop
      // focus before the slide-out transition begins.
      requestFindDismissal()
    } else {
      withAnimationAsNeeded(reduceMotion) { isFindVisible = true }
    }
  }

  /// macOS-standard "Use Selection for Find" (⌘E). Reads the WebView's
  /// current text selection, drops it into `findQuery`, reveals the
  /// bar, and runs the search. Falls back to plain `showFind` when
  /// the selection is empty or the JS read throws.
  ///
  /// `reduceMotion` is plumbed in from the call site so the bar's
  /// reveal animates consistently with the toolbar's `Action.find`
  /// path.
  func useSelectionForFind(reduceMotion: Bool) async {
    let selection = await currentSelection()
    let trimmed = selection.trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      withAnimationAsNeeded(reduceMotion) { isFindVisible = true }
      return
    }
    findQuery = trimmed
    withAnimationAsNeeded(reduceMotion) { isFindVisible = true }
    // The bar's `.onChange(of: findQuery)` is wired only once the
    // view mounts, so the synchronous assignment above wouldn't
    // trigger it on first reveal — drive the search explicitly.
    await performFind()
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
  /// `findQuery` intact so re-opening the bar with ⌘F restores the
  /// last query — matches Safari / Preview behavior.
  ///
  /// Synchronous so call sites can wrap the visibility flip in
  /// `withAnimation { ... }` (see `toggleTOC` for the same pattern).
  /// JS highlight teardown is fire-and-forget — observers don't care
  /// about its completion and it would block the animation otherwise.
  func hideFind() {
    isFindVisible = false
    findMatchCount = 0
    findMatchIndex = -1
    Task { await clearFindHighlights() }
  }

  /// Run the current `findQuery` against the rendered DOM. Empty
  /// queries clear highlights and reset the counters.
  func performFind() async {
    let trimmed = findQuery
    guard !trimmed.isEmpty else {
      await clearFindHighlights()
      findMatchCount = 0
      findMatchIndex = -1
      return
    }
    let escaped = jsStringLiteral(trimmed)
    let caseFlag = findCaseSensitive ? "true" : "false"
    let wholeFlag = findWholeWord ? "true" : "false"
    let script = """
      var r = window.galleyFind.search(\(escaped), \(caseFlag), \(wholeFlag));
      return [r.count, r.index];
      """
    do {
      let value = try await page.callJavaScript(script)
      let (count, index) = decodeFindResult(value)
      findMatchCount = count
      findMatchIndex = index
    } catch {
      findMatchCount = 0
      findMatchIndex = -1
    }
  }

  /// Cycle to the next match. No-op if there are no matches.
  func findNext() async {
    guard findMatchCount > 0 else { return }
    do {
      let value = try await page.callJavaScript(
        "return window.galleyFind.next();")
      findMatchIndex = decodeIntScalar(value) ?? findMatchIndex
    } catch {
      // Leave index unchanged on JS error — UI stays consistent.
    }
  }

  /// Cycle to the previous match. No-op if there are no matches.
  func findPrevious() async {
    guard findMatchCount > 0 else { return }
    do {
      let value = try await page.callJavaScript(
        "return window.galleyFind.prev();")
      findMatchIndex = decodeIntScalar(value) ?? findMatchIndex
    } catch {
      // Leave index unchanged on JS error — UI stays consistent.
    }
  }

  /// Tear down any `<mark>` wrappers the controller has installed.
  /// Safe to call even when no search has run; the JS side no-ops on
  /// an empty marks list.
  private func clearFindHighlights() async {
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
