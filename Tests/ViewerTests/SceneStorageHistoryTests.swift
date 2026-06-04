//
//  SceneStorageHistoryTests.swift
//  Galley
//
//  Validates that the per-window browsing history survives the exact
//  serialization round-trip `@SceneStorage("history")` performs at
//  app relaunch, and that the rehydrated value drives the restore
//  decision the way the live window does.
//
//  `@SceneStorage` itself is a SwiftUI property wrapper that can't be
//  driven from a unit test — but the *contract* it relies on is plain
//  value code we own:
//
//    write  (DocumentView.saveHistory):
//      model.historySnapshot.flatMap { try? SceneStoragePayload($0) }
//      → SwiftUI persists only the payload's `rawValue` (a JSON String).
//
//    read   (DocumentView.launchTask):
//      SwiftUI rehydrates SceneStoragePayload(rawValue: <persisted>)
//      → try? payload.value → BindPlan.decide(history:) → model.restore.
//
//  These tests reproduce that pipeline through the real
//  `SceneStoragePayload<HistorySnapshot>` wrapper and the real
//  `BindPlan.decide`, so a Codable-shape change, a wrapper regression,
//  or a restore-decision change can't silently strand every existing
//  window on relaunch. (`model.restore`'s own bounds-guard is covered
//  by the `HistorySnapshot.currentURL` / out-of-range cases below and
//  by the `DocumentModel.restore` guard it shares.)
//

import Foundation
import KosmosAppKit
import Testing
@testable import Galley

@Suite("SceneStorage history restoration")
struct SceneStorageHistoryTests {
  private let urlA = URL(fileURLWithPath: "/tmp/a.md")
  private let urlB = URL(fileURLWithPath: "/tmp/b.md")
  private let urlC = URL(fileURLWithPath: "/tmp/c.md")

  /// The write path `saveHistory()` performs: wrap a snapshot in the
  /// payload `@SceneStorage` actually stores.
  private func persist(_ snapshot: HistorySnapshot) throws
    -> SceneStoragePayload<HistorySnapshot>
  {
    try SceneStoragePayload(snapshot)
  }

  /// What SwiftUI hands back on relaunch: a fresh payload built from
  /// nothing but the persisted `rawValue` string.
  private func rehydrate(_ rawValue: String)
    -> SceneStoragePayload<HistorySnapshot>
  {
    SceneStoragePayload(rawValue: rawValue)
  }

  // MARK: Full save → persist-string → restore round-trip

  /// The crux: a window viewing the middle of its back/forward stack
  /// (user went A→B→C then stepped Back to B) must come back at B with
  /// the whole stack intact — Back *and* Forward both still available.
  /// This walks the value through the payload's `rawValue` so it tests
  /// exactly what lands on disk, not just `HistorySnapshot` Codable.
  @Test("Mid-stack position survives the @SceneStorage round-trip")
  func midStackPositionSurvives() throws {
    let saved = HistorySnapshot(
      urls: [urlA, urlB, urlC], currentIndex: 1)

    // write side: only `rawValue` is persisted by SwiftUI.
    let persisted = try persist(saved).rawValue
    // read side: SwiftUI reconstructs from that string alone.
    let restored = try rehydrate(persisted).value

    #expect(restored == saved)
    #expect(restored.urls == [urlA, urlB, urlC])
    #expect(restored.currentIndex == 1)
    #expect(restored.currentURL == urlB)
    // Back/forward affordances are preserved by the index landing
    // strictly inside the stack.
    #expect(restored.currentIndex > 0)                    // canGoBack
    #expect(restored.currentIndex < restored.urls.count - 1) // canGoForward
  }

  /// The persisted `rawValue` is plain JSON — the on-disk form must be
  /// stable and self-describing, not an opaque blob. Pin that it
  /// decodes independently of the wrapper.
  @Test("Persisted rawValue is decodable JSON")
  func persistedRawValueIsJSON() throws {
    let saved = HistorySnapshot(
      urls: [urlA, urlB], currentIndex: 0)
    let rawValue = try persist(saved).rawValue

    let decoded = try JSONDecoder().decode(
      HistorySnapshot.self, from: Data(rawValue.utf8))
    #expect(decoded == saved)
  }

  /// Paths with spaces ride through `URL.absoluteString` inside the
  /// JSON string — a regression here would corrupt restoration for any
  /// document under a "~/My Notes/" style folder.
  @Test("Spaces in paths survive the round-trip")
  func spacesSurvive() throws {
    let spaced = URL(fileURLWithPath: "/tmp/My Notes/a b.md")
    let saved = HistorySnapshot(urls: [spaced], currentIndex: 0)

    let restored = try rehydrate(persist(saved).rawValue).value
    #expect(restored.urls == [spaced])
    #expect(restored.currentURL == spaced)
  }

  // MARK: Round-trip wired into the restore decision

  /// End-to-end through the read path the window runs: rehydrated
  /// payload → `try? value` → `BindPlan.decide` → `.restore`. The plan
  /// must restore at the persisted current URL with no spurious
  /// per-window choice override when the window reopens on that URL.
  @Test("Rehydrated snapshot drives BindPlan to .restore at current URL")
  func rehydratedSnapshotRestores() throws {
    let saved = HistorySnapshot(
      urls: [urlA, urlB, urlC], currentIndex: 1)
    let rehydrated = try rehydrate(persist(saved).rawValue).value

    let plan = BindPlan.decide(
      target: DocumentTarget(url: urlB),
      didFirstBind: false,
      didRestore: false,
      history: rehydrated,
      perFileState: { _ in PerFileState() })

    guard case .restore(let snapshot, _, _) = plan.action else {
      Issue.record("Expected .restore, got \(plan.action)")
      return
    }
    #expect(snapshot == saved)
    #expect(snapshot.currentURL == urlB)
    #expect(!plan.applyChoiceOverrides)
  }

  /// When the window's WindowGroup binding resolved to a *different*
  /// URL than the restored snapshot's current URL, the restore path
  /// still fires on the snapshot's URL and signals the choice-override
  /// the interpreter needs — proving the persisted current position
  /// (not the binding) wins after a round-trip.
  @Test("Round-trip preserves the restored URL over the binding URL")
  func restoredURLWinsOverBinding() throws {
    let saved = HistorySnapshot(
      urls: [urlA, urlB, urlC], currentIndex: 2)
    let rehydrated = try rehydrate(persist(saved).rawValue).value

    let plan = BindPlan.decide(
      target: DocumentTarget(url: urlA),   // binding != snapshot.currentURL
      didFirstBind: false,
      didRestore: false,
      history: rehydrated,
      perFileState: { _ in PerFileState() })

    guard case .restore(let snapshot, _, _) = plan.action else {
      Issue.record("Expected .restore, got \(plan.action)")
      return
    }
    #expect(snapshot.currentURL == urlC)
    #expect(plan.applyChoiceOverrides)
  }

  // MARK: Defensive — a corrupt persisted string degrades gracefully

  /// If the persisted string is garbage (manual plist edit, truncated
  /// write, schema drift), `payload.value` throws. `launchTask` swallows
  /// it with `try?`, so `BindPlan` sees `history: nil` and falls through
  /// to `initialBind` — the window opens fresh rather than restoring
  /// corrupt state. Reproduce that exact swallow.
  @Test("Corrupt persisted string falls through to initialBind")
  func corruptStringFallsThrough() {
    let payload = rehydrate("}{ not json")

    // The launchTask read: `try? history?.value`.
    let history = try? payload.value
    #expect(history == nil)

    let plan = BindPlan.decide(
      target: DocumentTarget(url: urlA),
      didFirstBind: false,
      didRestore: false,
      history: history,
      perFileState: { _ in PerFileState() })

    #expect(plan.action == .initialBind(
      target: DocumentTarget(url: urlA), scrollY: nil, showsTOC: false))
    #expect(!plan.applyChoiceOverrides)
  }

  /// A single-entry stack (window never navigated) round-trips and
  /// restores to its only document with no Back/Forward — the common
  /// case for most windows.
  @Test("Single-entry stack round-trips")
  func singleEntryRoundTrips() throws {
    let saved = HistorySnapshot(urls: [urlA], currentIndex: 0)
    let restored = try rehydrate(persist(saved).rawValue).value

    #expect(restored == saved)
    #expect(restored.currentURL == urlA)
    #expect(restored.currentIndex == 0)                    // !canGoBack
    #expect(restored.currentIndex == restored.urls.count - 1) // !canGoForward
  }
}
