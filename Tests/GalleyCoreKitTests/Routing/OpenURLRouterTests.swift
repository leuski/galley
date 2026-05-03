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
    registry.register(WindowRecord(id: openWindow, currentURL: url))
    registry.register(WindowRecord(
      id: otherDoc,
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

  @Test("newWindow always spawns regardless of existing windows")
  func newWindowAlwaysSpawns() {
    var registry = WindowRegistry()
    registry.register(WindowRecord(id: ids.next(), currentURL: url))
    registry.register(WindowRecord(id: ids.next()))
    let action = router.decide(
      for: URL(fileURLWithPath: "/tmp/fresh.md"),
      behavior: .newWindow,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .openNew)
  }

  // MARK: - newTab behavior

  @Test("newTab onto frontmost window")
  func newTabOntoFront() {
    var registry = WindowRegistry()
    let doc = ids.next()
    registry.register(WindowRecord(id: doc))
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true,
      mainWindow: doc)
    #expect(action == .tabOnto(doc))
  }

  @Test("newTab spawns when registry is empty")
  func newTabSpawnsWhenEmpty() {
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: WindowRegistry(),
      handlerInstalled: true)
    #expect(action == .openNew)
  }

  // MARK: - replaceCurrent behavior

  @Test("replaceCurrent rebinds the frontmost window")
  func replaceFront() {
    var registry = WindowRegistry()
    let doc = ids.next()
    registry.register(WindowRecord(id: doc))
    let action = router.decide(
      for: url,
      behavior: .replaceCurrent,
      registry: registry,
      handlerInstalled: true,
      mainWindow: doc)
    #expect(action == .rebind(doc))
  }

  @Test("replaceCurrent spawns when registry is empty")
  func replaceSpawnsWhenEmpty() {
    let action = router.decide(
      for: url,
      behavior: .replaceCurrent,
      registry: WindowRegistry(),
      handlerInstalled: true)
    #expect(action == .openNew)
  }

  // MARK: - Frontmost-hint behavior

  @Test("Without main/key hints, newTab still picks any registered window")
  func newTabWithoutHints() {
    var registry = WindowRegistry()
    let doc = ids.next()
    registry.register(WindowRecord(id: doc))
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .tabOnto(doc))
  }
}
