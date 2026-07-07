//
//  DocumentSnapshotTests.swift
//  Galley
//
//  Pins the foundational value types for the windowing rebuild
//  (docs/rebuild-document-windowing.md): the per-window identity
//  `DocumentSceneID`, the always-non-empty `DocumentModel.History`,
//  and the single persistent shape `DocumentModel.Snapshot`.
//

import Foundation
import Testing
import GalleyCoreKit
@testable import KosmosAppKit
@testable import Galley

@MainActor
@Suite("Document windowing foundations")
struct DocumentSnapshotTests {
  @Test("DocumentSceneID mints distinct ids and is Codable round-trip")
  func sceneIDIdentityAndCoding() throws {
    let a = DocumentSceneID.next()
    let b = DocumentSceneID.next()
    #expect(a != b)
    #expect(a == a)
    #expect(!a.description.isEmpty)

    let data = try JSONEncoder().encode(a)
    let decoded = try JSONDecoder().decode(DocumentSceneID.self, from: data)
    #expect(decoded == a)
    #expect(decoded.description == a.description)
  }

  @Test("History always holds at least one URL")
  func historyIsNeverEmpty() {
    let url = URL(fileURLWithPath: "/tmp/a.md")
    let history = DocumentModel.History(url: url)
    #expect(!history.isEmpty)
    #expect(history.currentURL == url)
    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
  }

  @Test("History navigate/back/forward tracks the current URL")
  func historyNavigation() {
    let a = URL(fileURLWithPath: "/tmp/a.md")
    let b = URL(fileURLWithPath: "/tmp/b.md")
    var history = DocumentModel.History(url: a)

    history.navigate(to: b, leavingScrollY: 0)
    #expect(history.currentURL == b)
    #expect(history.canGoBack)
    #expect(!history.canGoForward)

    let wentBack = history.goBack(leavingScrollY: 0)
    #expect(wentBack)
    #expect(history.currentURL == a)
    #expect(!history.canGoBack)
    #expect(history.canGoForward)

    let wentForward = history.goForward(leavingScrollY: 0)
    #expect(wentForward)
    #expect(history.currentURL == b)
  }

  @Test("Back/Forward restores each entry's resting scroll position")
  func historyPreservesPerEntryScroll() {
    let a = URL(fileURLWithPath: "/tmp/a.md")
    let b = URL(fileURLWithPath: "/tmp/b.md")
    var history = DocumentModel.History(url: a)
    // A fresh entry starts at the top.
    #expect(history.currentScrollY == 0)

    // Leaving A at 250 stamps A; B is born at the top.
    history.navigate(to: b, leavingScrollY: 250)
    #expect(history.currentScrollY == 0)

    // Coming back to A restores 250; the leave stamps B at 800.
    _ = history.goBack(leavingScrollY: 800)
    #expect(history.currentURL == a)
    #expect(history.currentScrollY == 250)

    // Forward to B restores its 800.
    _ = history.goForward(leavingScrollY: 0)
    #expect(history.currentURL == b)
    #expect(history.currentScrollY == 800)
  }

  @Test("History decodes a legacy bare-URL snapshot at the top")
  func historyDecodesLegacyURLArray() throws {
    let json = #"{"urls":["file:///tmp/a.md","file:///tmp/b.md"],"currentIndex":1}"#
    let history = try JSONDecoder().decode(
      DocumentModel.History.self, from: Data(json.utf8))
    #expect(history.currentURL == URL(fileURLWithPath: "/tmp/b.md"))
    #expect(history.currentScrollY == 0)
    #expect(history.canGoBack)
  }

  @Test("Snapshot currentURL reflects its history")
  func snapshotCurrentURL() {
    let url = URL(fileURLWithPath: "/tmp/doc.md")
    let snapshot = DocumentModel.Snapshot(history: .init(url: url))
    #expect(snapshot.currentURL == url)
  }

  @Test("Snapshot is Codable round-trip with all persistent fields")
  func snapshotCoding() throws {
    let url = URL(fileURLWithPath: "/tmp/doc.md")
    // After the Selectable refactor the per-window choice overrides are
    // scene-persistent values (`PersistentSceneElement<NamedPair<…>>`),
    // each wrapping a `.local` pick.
    let original = DocumentModel.Snapshot(
      history: .init(url: url),
      scroll: .location(120.5),
      showsTOC: true,
      pageZoom: 1.25,
      templatePersistent: .init(
        value: .init(id: .init(rawValue: "aaa"), name: "template")),
      rendererPersistent: .init(
        value: .init(id: .init(rawValue: "bbb"), name: "processor")),
      colorSchemePersistent: .init(value: .init(id: .dark, name: "schema")),
      securityScopedBookmark: Data([0x01, 0x02]))

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      DocumentModel.Snapshot.self, from: data)

    // `Snapshot` is Codable-only (no `Equatable`) after the refactor, so
    // assert each persistent field survived the round trip individually.
    #expect(decoded.history == original.history)
    #expect(decoded.scroll == original.scroll)
    #expect(decoded.showsTOC == original.showsTOC)
    #expect(decoded.pageZoom == original.pageZoom)
    #expect(decoded.templatePersistent == original.templatePersistent)
    #expect(decoded.rendererPersistent == original.rendererPersistent)
    #expect(decoded.colorSchemePersistent == original.colorSchemePersistent)
    #expect(
      decoded.securityScopedBookmark == original.securityScopedBookmark)
  }

  @Test("Snapshot round-trips a line-target scroll")
  func snapshotCodingLineScroll() throws {
    let url = URL(fileURLWithPath: "/tmp/doc.md")
    let original = DocumentModel.Snapshot(
      history: .init(url: url),
      scroll: .line(42))

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      DocumentModel.Snapshot.self, from: data)
    #expect(decoded.scroll == original.scroll)
    #expect(decoded.scroll == .line(42))
    #expect(decoded.history == original.history)
  }
}
