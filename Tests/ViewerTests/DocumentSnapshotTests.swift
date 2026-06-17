//
//  DocumentSnapshotTests.swift
//  Galley
//
//  Pins the foundational value types for the windowing rebuild
//  (docs/rebuild-document-windowing.md): the per-window identity
//  `DocumentSceneID` and the single persistent shape
//  `DocumentModel.Snapshot`.
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

  @Test("Snapshot currentURL/hasDocument track history + index")
  func snapshotCurrentURL() {
    let empty = DocumentModel.Snapshot()
    #expect(empty.currentURL == nil)
    #expect(!empty.hasDocument)

    let a = URL(fileURLWithPath: "/tmp/a.md")
    let b = URL(fileURLWithPath: "/tmp/b.md")
    var s = DocumentModel.Snapshot(history: [a, b], currentIndex: 1)
    #expect(s.currentURL == b)
    #expect(s.hasDocument)

    // Out-of-range index degrades to nil rather than trapping.
    s.currentIndex = 9
    #expect(s.currentURL == nil)
  }

  @Test("Snapshot is Codable round-trip with all persistent fields")
  func snapshotCoding() throws {
    let url = URL(fileURLWithPath: "/tmp/doc.md")
    let original = DocumentModel.Snapshot(
      history: [url],
      currentIndex: 0,
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
