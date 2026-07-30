//
//  DocumentSnapshotTests.swift
//  Galley
//
//  Pins the foundational value types for the windowing rebuild
//  (docs/rebuild-document-windowing.md): the per-window identity
//  `DocumentSceneID` and the single persistent shape
//  `DocumentModel.Snapshot`. The nav stack itself is now the shared
//  `KosmosAppKit.WebPageHistory` — its behaviour is pinned in
//  `WebPageHistoryTests` over in KosmosAppKit; here we only assert that
//  a `Snapshot` embeds and round-trips one.
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
