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

    history.navigate(to: b)
    #expect(history.currentURL == b)
    #expect(history.canGoBack)
    #expect(!history.canGoForward)

    let wentBack = history.goBack()
    #expect(wentBack)
    #expect(history.currentURL == a)
    #expect(!history.canGoBack)
    #expect(history.canGoForward)

    let wentForward = history.goForward()
    #expect(wentForward)
    #expect(history.currentURL == b)
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
    let original = DocumentModel.Snapshot(
      history: .init(url: url),
      scrollY: 120.5,
      showsTOC: true,
      pageZoom: 1.25,
      templatePersistent: "tmpl",
      rendererPersistent: "rend",
      colorSchemePersistent: "dark",
      securityScopedBookmark: Data([0x01, 0x02]))

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
      DocumentModel.Snapshot.self, from: data)
    #expect(decoded == original)
  }
}
