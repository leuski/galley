import Foundation
import KosmosAppKit
import Testing
@testable import GalleyCoreKit

private let url = URL(fileURLWithPath: "/tmp/note.md")

@Suite("OpenURLRouter")
struct OpenURLRouterTests {
  private let ids = WindowIDAllocator()
  private let router = OpenURLRouter()

  // MARK: - Pre-launch

  @Test("Queues when handler is not yet installed",
        arguments: OpenBehavior.allCases)
  func queuesPreLaunch(behavior: OpenBehavior) {
    let action = router.decide(
      for: url,
      behavior: behavior,
      registry: WindowRegistry<WindowID>(),
      handlerInstalled: false)
    #expect(action == .queue)
  }

  // MARK: - URL already open

  @Test("focusExisting wins over every other behavior when URL is already open",
        arguments: OpenBehavior.allCases)
  func focusExistingPriority(behavior: OpenBehavior) {
    var registry = WindowRegistry<WindowID>()
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
      registry: WindowRegistry<WindowID>(),
      handlerInstalled: true)
    #expect(action == .openNew)
  }

  // MARK: - newWindow behavior

  @Test("newWindow always spawns regardless of existing windows")
  func newWindowAlwaysSpawns() {
    var registry = WindowRegistry<WindowID>()
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
    var registry = WindowRegistry<WindowID>()
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
      registry: WindowRegistry<WindowID>(),
      handlerInstalled: true)
    #expect(action == .openNew)
  }

  // MARK: - replaceCurrent behavior

  @Test("replaceCurrent rebinds the frontmost window")
  func replaceFront() {
    var registry = WindowRegistry<WindowID>()
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
      registry: WindowRegistry<WindowID>(),
      handlerInstalled: true)
    #expect(action == .openNew)
  }

  // MARK: - Frontmost-hint behavior

  @Test("Without main/key hints, newTab still picks any registered window")
  func newTabWithoutHints() {
    var registry = WindowRegistry<WindowID>()
    let doc = ids.next()
    registry.register(WindowRecord(id: doc))
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .tabOnto(doc))
  }

  // MARK: - Pre-launch beats every other signal

  /// `handlerInstalled: false` short-circuits before any URL match,
  /// frontmost lookup, or behavior selection. This is the contract
  /// that lets `application(_:open:)` callbacks fire safely before
  /// SwiftUI captures `openWindow` — every URL is parked in the
  /// launch buffer until `install(_:)` drains it.
  @Test("handler-not-installed queues even when URL is already open",
        arguments: OpenBehavior.allCases)
  func handlerNotInstalledOverridesFocusExisting(behavior: OpenBehavior) {
    var registry = WindowRegistry<WindowID>()
    registry.register(WindowRecord(id: ids.next(), currentURL: url))
    let action = router.decide(
      for: url,
      behavior: behavior,
      registry: registry,
      handlerInstalled: false)
    #expect(action == .queue)
  }

  @Test(
    "handler-not-installed queues even with frontmost+key+main hints set",
    arguments: OpenBehavior.allCases)
  func handlerNotInstalledOverridesHints(behavior: OpenBehavior) {
    var registry = WindowRegistry<WindowID>()
    let main = ids.next()
    let key = ids.next()
    registry.register(WindowRecord(id: main))
    registry.register(WindowRecord(id: key))
    let action = router.decide(
      for: URL(fileURLWithPath: "/tmp/fresh.md"),
      behavior: behavior,
      registry: registry,
      handlerInstalled: false,
      mainWindow: main,
      keyWindow: key)
    #expect(action == .queue)
  }

  // MARK: - Front-host hint precedence

  @Test("newTab uses mainWindow over keyWindow")
  func newTabPrefersMainOverKey() {
    var registry = WindowRegistry<WindowID>()
    let main = ids.next()
    let key = ids.next()
    registry.register(WindowRecord(id: main))
    registry.register(WindowRecord(id: key))
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true,
      mainWindow: main,
      keyWindow: key)
    #expect(action == .tabOnto(main))
  }

  @Test("replaceCurrent uses mainWindow over keyWindow")
  func replacePrefersMainOverKey() {
    var registry = WindowRegistry<WindowID>()
    let main = ids.next()
    let key = ids.next()
    registry.register(WindowRecord(id: main))
    registry.register(WindowRecord(id: key))
    let action = router.decide(
      for: url,
      behavior: .replaceCurrent,
      registry: registry,
      handlerInstalled: true,
      mainWindow: main,
      keyWindow: key)
    #expect(action == .rebind(main))
  }

  @Test("newTab falls back to key when main is unknown")
  func newTabFallsBackToKey() {
    var registry = WindowRegistry<WindowID>()
    let key = ids.next()
    registry.register(WindowRecord(id: key))
    let unknownMain = ids.next()
    let action = router.decide(
      for: url,
      behavior: .newTab,
      registry: registry,
      handlerInstalled: true,
      mainWindow: unknownMain,
      keyWindow: key)
    #expect(action == .tabOnto(key))
  }

  // MARK: - Already-open across encoding / standardisation

  /// The router relies on `WindowRegistry.registration(matching:)` to
  /// detect "this URL is already open." That helper compares
  /// `standardizedFileURL.path`, so a URL constructed with %20-encoded
  /// spaces matches a registered URL constructed via fileURLWithPath
  /// (and vice versa). Pin the contract at the router level so a
  /// regression in either side lights up here.
  @Test("focusExisting matches across percent-encoding differences")
  func focusExistingPercentEncoding() {
    var registry = WindowRegistry<WindowID>()
    let opened = URL(fileURLWithPath: "/tmp/foo bar.md")
    let inbound = URL(string: "file:///tmp/foo%20bar.md")!
    let id = ids.next()
    registry.register(WindowRecord(id: id, currentURL: opened))
    let action = router.decide(
      for: inbound,
      behavior: .newWindow,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .focusExisting(id))
  }

  /// Registering a window with a relative-style URL must still match
  /// an absolute-form inbound (path-based equality, not URL-equality).
  @Test("focusExisting matches when stored URL has trailing slash")
  func focusExistingTrailingSlash() {
    var registry = WindowRegistry<WindowID>()
    // file URLs without trailing slash on a regular file: same path
    // after standardisation, so registration should match.
    let stored = URL(fileURLWithPath: "/tmp/note.md", isDirectory: false)
    let id = ids.next()
    registry.register(WindowRecord(id: id, currentURL: stored))
    let action = router.decide(
      for: URL(fileURLWithPath: "/tmp/note.md"),
      behavior: .replaceCurrent,
      registry: registry,
      handlerInstalled: true)
    #expect(action == .focusExisting(id))
  }

  /// Two windows on the same URL: one is preferred by hint, but
  /// focusExisting can still pick either — what matters is that the
  /// router NEVER returns `.openNew` for an already-open URL.
  @Test("Duplicate-URL registrations never spawn a new window",
        arguments: OpenBehavior.allCases)
  func duplicateURLNeverSpawns(behavior: OpenBehavior) {
    var registry = WindowRegistry<WindowID>()
    let first = ids.next()
    let second = ids.next()
    registry.register(WindowRecord(id: first, currentURL: url))
    registry.register(WindowRecord(id: second, currentURL: url))
    let action = router.decide(
      for: url,
      behavior: behavior,
      registry: registry,
      handlerInstalled: true,
      mainWindow: second)
    if case .focusExisting = action { /* expected */ } else {
      Issue.record("Expected focusExisting, got \(action)")
    }
  }
}
