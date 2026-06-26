import Foundation
import Testing
@testable import GalleyCoreKit
internal import ALFoundation

/// Pins the resolution contract the Quick Look in-process path relies on:
/// `existingTemplate(forID:) ?? .bundledDefault` — use the stored
/// template when it resolves, otherwise the bundled default.
@Suite("Stored-template resolution")
@MainActor
struct TemplateResolutionTests {
  private func seededStore(name: String) throws -> (TemplateStore, URL) {
    let tmp = URL.temporaryDirectory
      / "TemplateResolutionTests-\(UUID().uuidString)"
    try tmp.createDirectory()
    let folder = tmp / name
    try folder.createDirectory()
    try "<html></html>".write(
      to: folder / "Template.html", atomically: true, encoding: .utf8)
    return (TemplateStore(directoryURLs: [tmp]), tmp)
  }

  @Test("a known stored id resolves to that template")
  func resolvesKnownID() throws {
    let (store, tmp) = try seededStore(name: "MyTheme")
    defer { try? tmp.remove() }
    let resolved = store.existingTemplate(forID: .init(rawValue: "0.MyTheme"))
      ?? .bundledDefault
    #expect(resolved.id.rawValue == "0.MyTheme")
  }

  @Test("an unknown stored id falls back to the bundled default")
  func fallsBackOnUnknownID() throws {
    let (store, tmp) = try seededStore(name: "MyTheme")
    defer { try? tmp.remove() }
    let resolved = store.existingTemplate(forID: .init(rawValue: "9.Missing"))
      ?? .bundledDefault
    #expect(resolved.id == Template.bundledDefault.id)
  }

  @Test("a nil stored id falls back to the bundled default")
  func fallsBackOnNilID() throws {
    let (store, tmp) = try seededStore(name: "MyTheme")
    defer { try? tmp.remove() }
    let resolved = store.existingTemplate(forID: nil) ?? .bundledDefault
    #expect(resolved.id == Template.bundledDefault.id)
  }
}
