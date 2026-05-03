import Foundation
import Testing
@testable import GalleyCoreKit

private final class IDFountain: @unchecked Sendable {
  private var allocator = WindowIDAllocator()
  func next() -> WindowID { allocator.next() }
}

private let url = URL(fileURLWithPath: "/tmp/note.md")

@Suite("OpenURLRouter")
struct OpenURLRouterTests {
  private let ids = IDFountain()
  private let router = OpenURLRouter()

  // MARK: - Pre-launch

  @Test("Queues when handler is not yet installed",
        arguments: OpenBehavior.allCases)
  func queuesPreLaunch(behavior: OpenBehavior) {
    let action = router.decide(
      for: url,
      behavior: behavior,
      registry: WindowRegistry(),
      handlerInstalled: false)
    #expect(action == .queue)
  }

  // MARK: - URL already open

  @Test("focusExisting wins over every other behavior when URL is already open",
        arguments: OpenBehavior.allCases)
  func focusExistingPriority(behavior: OpenBehavior) {
    var registry = WindowRegistry()
    let openWindow = ids.next()
    let otherDoc = ids.next()
    registry.register(WindowRecord(
      id: openWindow, hasDocument: true, currentURL: url))
    registry.register(WindowRecord(
      id: otherDoc,
      hasDocument: true,
      currentURL: URL(fileURLWithPath: "/tmp/other.md")))
    let action = router.decide(
      for: url,
      behavior: behavior,
      registry: registry,
      handlerInstalled: true,
      mainWindow: otherDoc)
    #expect(action == .focusExisting(openWindow))
  }

  // MARK: - Empty registry

  @Test("Empty registry: every behavior spawns a new window",
        arguments: OpenBehavior.allCases)
  func emptyRegistrySpawns(behavior: OpenBehavior) {
    let action = router.decide(
      for: url,
      behavior: behavior,
      registry: WindowRegistry(),
      handlerInstalled: true)
    #expect(action == .openNew)
  }

  // MARK: - newWindow behavior

  @Test("newWindow rebinds the placeholder when no doc window exists")
  func newWindowReusesLonePlaceholder() {
    var registry = WindowRegistry()
    let placeholder = ids.next()
    registry.register(WindowRecord(id: placeholder))
    let action = router.decide(
      for: url,
      behavior: .newWindow,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .rebind(placeholder))
  }

  @Test("newWindow ignores the placeholder when a doc window exists")
  func newWindowIgnoresPlaceholderWhenDocExists() {
    var registry = WindowRegistry()
    let doc = ids.next()
    let placeholder = ids.next()
    registry.register(WindowRecord(id: doc, hasDocument: true))
    registry.register(WindowRecord(id: placeholder))
    let action = router.decide(
      for: url,
      behavior: .newWindow,
      registry: registry,
      handlerInstalled: true,
      mainWindow: doc)
    #expect(action == .openNew)
  }

  // MARK: - newTab behavior

  @Test("newTab onto frontmost document window")
  func newTabOntoFront() {
    var registry = WindowRegistry()
    let doc = ids.next()
    registry.register(WindowRecord(id: doc, hasDocument: true))
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true,
      mainWindow: doc)
    #expect(action == .tabOnto(doc))
  }

  @Test("newTab falls back to placeholder rebind when no real doc window")
  func newTabFallsBackToPlaceholder() {
    var registry = WindowRegistry()
    let placeholder = ids.next()
    registry.register(WindowRecord(id: placeholder))
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .rebind(placeholder))
  }

  // MARK: - replaceCurrent behavior

  @Test("replaceCurrent rebinds the frontmost document window")
  func replaceFrontDocument() {
    var registry = WindowRegistry()
    let doc = ids.next()
    registry.register(WindowRecord(id: doc, hasDocument: true))
    let action = router.decide(
      for: url,
      behavior: .replaceCurrent,
      registry: registry,
      handlerInstalled: true,
      mainWindow: doc)
    #expect(action == .rebind(doc))
  }

  @Test("replaceCurrent falls back to placeholder when no real doc")
  func replaceFallsBackToPlaceholder() {
    var registry = WindowRegistry()
    let placeholder = ids.next()
    registry.register(WindowRecord(id: placeholder))
    let action = router.decide(
      for: url,
      behavior: .replaceCurrent,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .rebind(placeholder))
  }

  // MARK: - Frontmost-hint behavior

  @Test("Without main/key hints, newTab still picks any document window")
  func newTabWithoutHints() {
    var registry = WindowRegistry()
    let doc = ids.next()
    registry.register(WindowRecord(id: doc, hasDocument: true))
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true)
    // mainWindow/keyWindow nil — falls back to "any doc" lookup.
    #expect(action == .tabOnto(doc))
  }
}
