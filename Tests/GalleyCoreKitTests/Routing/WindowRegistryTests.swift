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

  // MARK: - Idempotence and unknown-id resilience

  /// Re-registering the same `WindowID` overwrites the existing
  /// record. Production calls into here every time `ContentView`
  /// rebinds, and SwiftUI can re-fire the `WindowAccessor.onAttach`
  /// path when scene state is reused — the registry must stay
  /// consistent rather than accumulating duplicate records.
  @Test("Re-registering same id overwrites the previous record")
  func reRegisterOverwrites() {
    var registry = WindowRegistry()
    let id = ids.next()
    let first = URL(fileURLWithPath: "/tmp/a.md")
    let second = URL(fileURLWithPath: "/tmp/b.md")
    registry.register(WindowRecord(id: id, currentURL: first))
    registry.register(WindowRecord(id: id, currentURL: second))
    #expect(registry.all.count == 1)
    #expect(registry.record(for: id)?.currentURL == second)
  }

  @Test("unregister of unknown id is a no-op")
  func unregisterUnknownIsNoOp() {
    var registry = WindowRegistry()
    let known = ids.next()
    registry.register(WindowRecord(id: known))
    let unknown = ids.next()
    registry.unregister(unknown)
    #expect(registry.record(for: known) != nil)
    #expect(registry.all.count == 1)
  }

  @Test("updateCurrentURL on unknown id is a no-op")
  func updateCurrentURLUnknownIsNoOp() {
    var registry = WindowRegistry()
    let known = ids.next()
    let url = URL(fileURLWithPath: "/tmp/a.md")
    registry.register(WindowRecord(id: known, currentURL: url))
    let unknown = ids.next()
    registry.updateCurrentURL(unknown, URL(fileURLWithPath: "/tmp/x.md"))
    #expect(registry.record(for: known)?.currentURL == url)
    #expect(registry.record(for: unknown) == nil)
  }

  // MARK: - Value-type semantics

  /// `WindowRegistry` is a value type so the dispatcher can hand the
  /// router an immutable snapshot per call. Verify the snapshot is
  /// independent of subsequent mutation (which would be a soundness
  /// bug if struct semantics ever changed).
  @Test("Registry copies are independent (value semantics)")
  func valueSemantics() {
    var original = WindowRegistry()
    let id = ids.next()
    original.register(WindowRecord(id: id))
    var snapshot = original
    let other = ids.next()
    original.register(WindowRecord(id: other))
    #expect(snapshot.all.count == 1)
    #expect(original.all.count == 2)
  }

  // MARK: - WindowIDAllocator

  @Test("Allocator issues strictly monotonic, distinct IDs")
  func allocatorMonotonic() {
    var allocator = WindowIDAllocator()
    var seen: Set<UInt64> = []
    var prev: UInt64 = 0
    for _ in 0..<1_000 {
      let id = allocator.next()
      #expect(seen.insert(id.raw).inserted, "duplicate ID \(id.raw)")
      #expect(id.raw > prev)
      prev = id.raw
    }
  }

  @Test("Allocator copies fork independently (value semantics)")
  func allocatorValueSemantics() {
    var first = WindowIDAllocator()
    _ = first.next()
    _ = first.next()
    var fork = first
    let firstNext = first.next()
    let forkNext = fork.next()
    // Same counter state at fork time — both forks issue the same
    // next id, then diverge as each is mutated.
    #expect(firstNext.raw == forkNext.raw)
    let firstAfter = first.next()
    let forkAfter = fork.next()
    #expect(firstAfter.raw == forkAfter.raw)
  }

  // MARK: - registration(matching:) edge cases

  /// If two windows ever bind to the same URL (e.g. a router race or
  /// a manual tab open of an already-visible doc), `registration`
  /// must still return *some* record — never nil — so the router
  /// never falls back to "spawn another." Doesn't pin which one wins
  /// because dictionary iteration order is undefined.
  @Test("registration(matching:) returns one record when multiples share a URL")
  func matchingDuplicates() {
    var registry = WindowRegistry()
    let url = URL(fileURLWithPath: "/tmp/dup.md")
    let a = ids.next()
    let b = ids.next()
    registry.register(WindowRecord(id: a, currentURL: url))
    registry.register(WindowRecord(id: b, currentURL: url))
    let match = registry.registration(matching: url)
    #expect(match != nil)
    #expect(match?.id == a || match?.id == b)
  }

  /// `registration` ignores records whose currentURL points at a
  /// different file even if the inbound URL is just a substring or
  /// directory ancestor.
  @Test("registration(matching:) does not match a sibling under same dir")
  func matchingDoesNotMatchSibling() {
    var registry = WindowRegistry()
    let stored = URL(fileURLWithPath: "/tmp/a.md")
    registry.register(WindowRecord(id: ids.next(), currentURL: stored))
    let other = URL(fileURLWithPath: "/tmp/b.md")
    #expect(registry.registration(matching: other) == nil)
  }

  /// Reverse direction of the existing percent-encoding test: the
  /// stored URL is encoded, the inbound is plain. Both sides go
  /// through `standardizedFileURL.path`, so equality holds.
  @Test("registration(matching:) handles inbound plain vs stored encoded")
  func matchingReverseEncoding() {
    var registry = WindowRegistry()
    let id = ids.next()
    let storedEncoded = URL(string: "file:///tmp/foo%20bar.md")!
    registry.register(WindowRecord(id: id, currentURL: storedEncoded))
    let plain = URL(fileURLWithPath: "/tmp/foo bar.md")
    #expect(registry.registration(matching: plain)?.id == id)
  }
}
