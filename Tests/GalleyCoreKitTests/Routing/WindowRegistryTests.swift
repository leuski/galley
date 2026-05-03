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

  @Test("Empty registry has no records")
  func emptyByDefault() {
    let registry = WindowRegistry()
    #expect(registry.all.isEmpty)
    #expect(registry.isEmpty)
    #expect(registry.frontmost() == nil)
  }

  @Test("Register, lookup, unregister round-trip")
  func registerLookupUnregister() {
    var registry = WindowRegistry()
    let id = ids.next()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    registry.register(WindowRecord(id: id, currentURL: url))
    #expect(registry.record(for: id)?.currentURL == url)
    #expect(registry.all.count == 1)
    #expect(!registry.isEmpty)
    registry.unregister(id)
    #expect(registry.record(for: id) == nil)
    #expect(registry.all.isEmpty)
    #expect(registry.isEmpty)
  }

  @Test("updateCurrentURL writes through")
  func updateCurrentURL() {
    var registry = WindowRegistry()
    let id = ids.next()
    registry.register(WindowRecord(id: id))
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
    registry.register(WindowRecord(id: id, currentURL: stored))
    let lookup = URL(string: "file:///tmp/foo%20bar.md")!
    #expect(registry.registration(matching: lookup)?.id == id)
  }

  @Test("registration(matching:) skips records without a URL")
  func matchingSkipsEmpty() {
    var registry = WindowRegistry()
    registry.register(WindowRecord(id: ids.next()))
    let url = URL(fileURLWithPath: "/tmp/x.md")
    #expect(registry.registration(matching: url) == nil)
  }

  @Test("frontmost prefers mainWindow hint")
  func frontmostPrefersMain() {
    var registry = WindowRegistry()
    let main = ids.next()
    let key = ids.next()
    let other = ids.next()
    registry.register(WindowRecord(id: main))
    registry.register(WindowRecord(id: key))
    registry.register(WindowRecord(id: other))
    let chosen = registry.frontmost(mainWindow: main, keyWindow: key)
    #expect(chosen?.id == main)
  }

  @Test("frontmost falls back to keyWindow then any")
  func frontmostFallbacks() {
    var registry = WindowRegistry()
    let key = ids.next()
    let other = ids.next()
    registry.register(WindowRecord(id: key))
    registry.register(WindowRecord(id: other))

    // mainWindow hint not in registry: fall back to keyWindow.
    let unknown = ids.next()
    let viaKey = registry.frontmost(mainWindow: unknown, keyWindow: key)
    #expect(viaKey?.id == key)

    // Neither hint registered: any record.
    let viaAny = registry.frontmost(mainWindow: unknown, keyWindow: unknown)
    #expect(viaAny != nil)
  }

  @Test("frontmost returns nil for empty registry")
  func frontmostNilWhenEmpty() {
    let registry = WindowRegistry()
    #expect(registry.frontmost() == nil)
    #expect(registry.frontmost(mainWindow: WindowID(raw: 1)) == nil)
  }
}
