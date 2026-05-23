import Foundation
import Testing
internal import ALFoundation
@testable import GalleyCoreKit

@Suite("GalleyAppHash")
struct GalleyAppHashTests {

  private func makeTreeRoot() throws -> URL {
    let root = URL.temporaryDirectory / "GalleyAppHashTest-\(UUID().uuidString)"
    try root.createDirectory()
    return root
  }

  @Test("identical trees hash identically")
  func identicalTreesAreEqual() async throws {
    let root1 = try makeTreeRoot()
    let root2 = try makeTreeRoot()
    defer {
      try? root1.remove()
      try? root2.remove()
    }
    for tree in [root1, root2] {
      try "alpha".write(
        to: tree.appending(path: "one.txt"),
        atomically: true, encoding: .utf8)
      try "beta".write(
        to: tree.appending(path: "two.txt"),
        atomically: true, encoding: .utf8)
    }
    let hash1 = try await GalleyAppHash.compute(at: root1)
    let hash2 = try await GalleyAppHash.compute(at: root2)
    #expect(hash1 == hash2)
  }

  @Test("changing a file's content changes the hash")
  func contentChangeChangesHash() async throws {
    let root = try makeTreeRoot()
    defer { try? root.remove() }
    let file = root.appending(path: "x.txt")
    try "before".write(to: file, atomically: true, encoding: .utf8)
    let hash1 = try await GalleyAppHash.compute(at: root)
    try "after".write(to: file, atomically: true, encoding: .utf8)
    let hash2 = try await GalleyAppHash.compute(at: root)
    #expect(hash1 != hash2)
  }

  @Test("renaming a file changes the hash")
  func renameChangesHash() async throws {
    let root = try makeTreeRoot()
    defer { try? root.remove() }
    let original = root.appending(path: "original.txt")
    try "payload".write(to: original, atomically: true, encoding: .utf8)
    let hash1 = try await GalleyAppHash.compute(at: root)
    try original.move(to: root / "renamed.txt")
    let hash2 = try await GalleyAppHash.compute(at: root)
    #expect(hash1 != hash2)
  }
}
