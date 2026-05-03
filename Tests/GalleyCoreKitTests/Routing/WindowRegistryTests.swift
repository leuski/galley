import Foundation
import Testing
@testable import GalleyCoreKit

/// Per-suite allocator so each test's `ids.next()` calls produce
/// distinct, stable IDs without depending on object lifetimes.
private final class IDFountain: @unchecked Sendable {
  private var allocator = WindowIDAllocator()
  func next() -> WindowID { allocator.next() }
}

@Suite("WindowRegistry")
struct WindowRegistryTests {
  private let ids = IDFountain()

  @Test("Empty registry has no documents and no records")
  func emptyByDefault() {
    let registry = WindowRegistry()
    #expect(registry.all.isEmpty)
    #expect(!registry.hasAnyDocumentWindow)
    #expect(registry.frontmostDocument() == nil)
    #expect(registry.frontmostPlaceholder() == nil)
  }

  @Test("Register, lookup, unregister round-trip")
  func registerLookupUnregister() {
    var registry = WindowRegistry()
    let id = ids.next()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    registry.register(WindowRecord(
      id: id, hasDocument: true, currentURL: url))
    #expect(registry.record(for: id)?.currentURL == url)
    #expect(registry.all.count == 1)
    registry.unregister(id)
    #expect(registry.record(for: id) == nil)
    #expect(registry.all.isEmpty)
  }

  @Test("markReady flips a placeholder into a document window")
  func markReadyFlips() {
    var registry = WindowRegistry()
    let id = ids.next()
    registry.register(WindowRecord(id: id))
    #expect(registry.record(for: id)?.hasDocument == false)
    #expect(registry.frontmostPlaceholder()?.id == id)
    #expect(!registry.hasAnyDocumentWindow)

    registry.markReady(id)
    #expect(registry.record(for: id)?.hasDocument == true)
    #expect(registry.hasAnyDocumentWindow)
    #expect(registry.frontmostPlaceholder() == nil)
  }

  @Test("updateCurrentURL writes through")
  func updateCurrentURL() {
    var registry = WindowRegistry()
    let id = ids.next()
    registry.register(WindowRecord(id: id, hasDocument: true))
    let url = URL(fileURLWithPath: "/tmp/x.md")
    registry.updateCurrentURL(id, url)
    #expect(registry.record(for: id)?.currentURL == url)
    registry.updateCurrentURL(id, nil)
    #expect(registry.record(for: id)?.currentURL == nil)
  }

  @Test("registration(matching:) finds bound URL across paths")
  func matchingByPath() {
    var registry = WindowRegistry()
    let id = ids.next()
    let stored = URL(fileURLWithPath: "/tmp/foo bar.md")
    registry.register(WindowRecord(
      id: id, hasDocument: true, currentURL: stored))
    let lookup = URL(string: "file:///tmp/foo%20bar.md")!
    #expect(registry.registration(matching: lookup)?.id == id)
  }

  @Test("registration(matching:) skips placeholders without a URL")
  func matchingSkipsEmpty() {
    var registry = WindowRegistry()
    registry.register(WindowRecord(id: ids.next()))
    let url = URL(fileURLWithPath: "/tmp/x.md")
    #expect(registry.registration(matching: url) == nil)
  }

  @Test("frontmostDocument prefers mainWindow hint")
  func frontmostPrefersMain() {
    var registry = WindowRegistry()
    let main = ids.next()
    let key = ids.next()
    let other = ids.next()
    registry.register(WindowRecord(id: main, hasDocument: true))
    registry.register(WindowRecord(id: key, hasDocument: true))
    registry.register(WindowRecord(id: other, hasDocument: true))
    let chosen = registry.frontmostDocument(
      mainWindow: main, keyWindow: key)
    #expect(chosen?.id == main)
  }

  @Test("frontmostDocument falls back to keyWindow then any")
  func frontmostFallbacks() {
    var registry = WindowRegistry()
    let key = ids.next()
    let other = ids.next()
    registry.register(WindowRecord(id: key, hasDocument: true))
    registry.register(WindowRecord(id: other, hasDocument: true))

    // mainWindow hint not in registry: fall back to keyWindow.
    let unknown = ids.next()
    let viaKey = registry.frontmostDocument(
      mainWindow: unknown, keyWindow: key)
    #expect(viaKey?.id == key)

    // Neither hint registered: any document window.
    let viaAny = registry.frontmostDocument(
      mainWindow: unknown, keyWindow: unknown)
    #expect(viaAny != nil)
    #expect(viaAny?.hasDocument == true)
  }

  @Test("frontmostDocument ignores placeholders even when hinted")
  func frontmostIgnoresPlaceholders() {
    var registry = WindowRegistry()
    let placeholder = ids.next()
    let real = ids.next()
    registry.register(WindowRecord(id: placeholder, hasDocument: false))
    registry.register(WindowRecord(id: real, hasDocument: true))
    let chosen = registry.frontmostDocument(
      mainWindow: placeholder, keyWindow: nil)
    #expect(chosen?.id == real)
  }

  @Test("frontmostDocument returns nil when only placeholders exist")
  func frontmostNilWithOnlyPlaceholders() {
    var registry = WindowRegistry()
    registry.register(WindowRecord(id: ids.next()))
    registry.register(WindowRecord(id: ids.next()))
    #expect(registry.frontmostDocument() == nil)
  }
}
