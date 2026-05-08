import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("GalleyAppHash")
struct GalleyAppHashTests {

  private func makeTreeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "GalleyAppHashTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("identical trees hash identically")
  func identicalTreesAreEqual() async throws {
    let a = try makeTreeRoot()
    let b = try makeTreeRoot()
    defer {
      try? FileManager.default.removeItem(at: a)
      try? FileManager.default.removeItem(at: b)
    }
    for tree in [a, b] {
      try "alpha".write(
        to: tree.appending(path: "one.txt"),
        atomically: true, encoding: .utf8)
      try "beta".write(
        to: tree.appending(path: "two.txt"),
        atomically: true, encoding: .utf8)
    }
    let h1 = try await GalleyAppHash.compute(at: a)
    let h2 = try await GalleyAppHash.compute(at: b)
    #expect(h1 == h2)
  }

  @Test("changing a file's content changes the hash")
  func contentChangeChangesHash() async throws {
    let root = try makeTreeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "x.txt")
    try "before".write(to: file, atomically: true, encoding: .utf8)
    let h1 = try await GalleyAppHash.compute(at: root)
    try "after".write(to: file, atomically: true, encoding: .utf8)
    let h2 = try await GalleyAppHash.compute(at: root)
    #expect(h1 != h2)
  }

  @Test("renaming a file changes the hash")
  func renameChangesHash() async throws {
    let root = try makeTreeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appending(path: "original.txt")
    try "payload".write(to: original, atomically: true, encoding: .utf8)
    let h1 = try await GalleyAppHash.compute(at: root)
    try FileManager.default.moveItem(
      at: original, to: root.appending(path: "renamed.txt"))
    let h2 = try await GalleyAppHash.compute(at: root)
    #expect(h1 != h2)
  }
}
