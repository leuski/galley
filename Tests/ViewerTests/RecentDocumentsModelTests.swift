//
//  RecentDocumentsModelTests.swift
//  Galley
//
//  Pins the unified (single-path) behavior of `RecentDocumentsModel`:
//  one store backed by `Defaults.recentEntries`, `urls` derived from
//  it, most-recent-first ordering, dedup on re-record, and the cap.
//  Remote (galley://) URLs are used throughout so the tests stay
//  hermetic — they take the no-bookmark path and never touch the
//  filesystem. The suite snapshots the shared defaults key in `init`
//  and restores it in `deinit` so it doesn't leak into the real
//  recents list or other tests.
//

import Foundation
import Testing
@testable import Galley

@MainActor
@Suite("RecentDocumentsModel")
struct RecentDocumentsModelTests {
  private let saved: [RecentDocumentEntry]

  init() {
    saved = Defaults.shared.recentEntries
    Defaults.shared.recentEntries = []
  }

  // Swift Testing runs deinit after each test; restore the real list.
  // (deinit can't be @MainActor-isolated, but assigning a Sendable
  // value to the defaults key is safe from the deinit context.)
  func restore() {
    Defaults.shared.recentEntries = saved
  }

  private func remoteURL(_ name: String) throws -> URL {
    try #require(URL(string: "galley://example/\(name)"))
  }

  @Test("record prepends most-recent-first and urls mirrors entries")
  func recordPrependsMostRecentFirst() throws {
    defer { restore() }
    let docA = try remoteURL("a.md")
    let docB = try remoteURL("b.md")
    let recents = RecentDocumentsModel()
    recents.record(docA)
    recents.record(docB)
    #expect(recents.urls == [docB, docA])
    #expect(recents.urls == recents.entries.map(\.url))
  }

  @Test("re-recording an existing URL dedupes and promotes it to front")
  func reRecordDedupesAndPromotes() throws {
    defer { restore() }
    let docA = try remoteURL("a.md")
    let docB = try remoteURL("b.md")
    let docC = try remoteURL("c.md")
    let recents = RecentDocumentsModel()
    recents.record(docA)
    recents.record(docB)
    recents.record(docC)
    recents.record(docA)
    #expect(recents.urls == [docA, docC, docB])
  }

  @Test("record caps the list at maxItems, dropping the oldest")
  func recordCapsAtMaxItems() throws {
    defer { restore() }
    let urls = try (0..<(RecentDocumentsModel.maxItems + 5))
      .map { try remoteURL("doc\($0).md") }
    let recents = RecentDocumentsModel()
    for url in urls { recents.record(url) }
    #expect(recents.urls.count == RecentDocumentsModel.maxItems)
    // Newest-first: the last recorded is at the front, the oldest
    // (urls.first) has fallen off the end.
    #expect(recents.urls.first == urls.last)
    #expect(!recents.urls.contains(urls[0]))
  }

  @Test("clearAll empties the list and persists the empty state")
  func clearAllEmptiesAndPersists() throws {
    defer { restore() }
    let docA = try remoteURL("a.md")
    let recents = RecentDocumentsModel()
    recents.record(docA)
    recents.clearAll()
    #expect(recents.urls.isEmpty)
    #expect(Defaults.shared.recentEntries.isEmpty)
  }

  @Test("a fresh model hydrates urls from the persisted store")
  func hydratesFromPersistedStore() throws {
    defer { restore() }
    let docA = try remoteURL("a.md")
    let docB = try remoteURL("b.md")
    Defaults.shared.recentEntries = [
      .init(url: docB, bookmark: nil),
      .init(url: docA, bookmark: nil)
    ]
    let recents = RecentDocumentsModel()
    #expect(recents.urls == [docB, docA])
  }

  @Test("remove drops one entry and leaves the rest ordered")
  func removeDropsOneEntry() throws {
    defer { restore() }
    let docA = try remoteURL("a.md")
    let docB = try remoteURL("b.md")
    let recents = RecentDocumentsModel()
    recents.record(docA)
    recents.record(docB)
    recents.remove(docA)
    #expect(recents.urls == [docB])
  }
}
