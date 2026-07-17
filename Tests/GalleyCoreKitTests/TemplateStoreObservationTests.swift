import Foundation
import Testing

@testable import GalleyCoreKit
internal import ALFoundation

// MARK: - Helpers

@MainActor
private func makeTempDir() -> URL {
  let tmp = URL.temporaryDirectory
  / "TemplateStoreObservationTests-\(UUID().uuidString)"
  try? tmp.createDirectory()
  return tmp
}

@MainActor
private func writeFolderTemplate(at root: URL, name: String) throws {
  let folder = root / name
  try folder.createDirectory()
  try "<html></html>".write(
    to: folder / "Template.html",
    atomically: true, encoding: .utf8)
}

// MARK: - Folder → TemplateStore

@Suite("TemplateStore observes its folder")
@MainActor
struct TemplateStoreObservationTests {

  @Test("reload() picks up a newly added folder template")
  func reloadPicksUpNewTemplate() throws {
    let tmp = makeTempDir()
    defer { try? tmp.remove() }
    let store = TemplateStore(directoryURLs: [tmp])

    #expect(store.values.isEmpty)

    try writeFolderTemplate(at: tmp, name: "MyTheme")
    store.reload()

    #expect(store.values.count == 1)
    #expect(store.values.contains(where: { $0.id.rawValue == "0.MyTheme" }))
  }

  @Test("reload() drops a deleted folder template")
  func reloadDropsDeletedTemplate() throws {
    let tmp = makeTempDir()
    defer { try? tmp.remove() }
    try writeFolderTemplate(at: tmp, name: "Doomed")
    let store = TemplateStore(directoryURLs: [tmp])
    #expect(store.values.count == 1)

    try tmp.appending(path: "Doomed").remove()
    store.reload()

    #expect(store.values.isEmpty)
  }

  @Test("multi-source: bundled and user templates with same name coexist")
  func multiSourceNoCollision() throws {
    let bundleSim = makeTempDir()
    let userSim = makeTempDir()
    defer {
      try? bundleSim.remove()
      try? userSim.remove()
    }
    try writeFolderTemplate(at: bundleSim, name: "Default")
    try writeFolderTemplate(at: userSim, name: "Default")
    let store = TemplateStore(directoryURLs: [bundleSim, userSim])

    let ids = store.values.map(\.id).sorted().map(\.rawValue)
    #expect(ids == ["0.Default", "1.Default"])
  }

  // Note: an FSEvents-driven watcher integration test is intentionally
  // omitted. FSEvents is unreliable for short-lived tmp directories
  // under `/var/folders/...` (latency, coalescing, exclusion lists),
  // and the observation chain it feeds — `reload()` mutating
  // `store.values`, which propagates to `Choice.values` — is
  // already covered in KosmosAppKit by calling `reload()` directly.
}
