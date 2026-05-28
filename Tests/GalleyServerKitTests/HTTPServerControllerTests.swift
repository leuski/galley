#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

/// Behaviour pins for the generic lifecycle controller that
/// `PreviewServerController` now delegates to. These tests do NOT
/// touch any Galley-specific provider — they construct an empty
/// `Router<BasicRequestContext>` so the assertions hold for any
/// caller of `HTTPServerController`, not just the preview-server
/// facade.
///
/// Real sockets are opened against `127.0.0.1` on an OS-assigned port.
/// Tests are bounded by a small polling timeout so a stuck listener
/// fails the test instead of hanging CI.
@Suite("HTTPServerController")
@MainActor
struct HTTPServerControllerTests {
  private let bindTimeout: Duration = .seconds(3)
  private let stopTimeout: Duration = .seconds(3)

  private func makeController() -> HTTPServerController {
    HTTPServerController()
  }

  /// Starts a fresh controller bound to loopback with an empty router
  /// (all requests would 404). Returns once the bound URL is observed
  /// or the timeout expires. Used by the bind/stop/restart tests
  /// below so each one focuses on the transition under test.
  private func startAndAwaitRunning(
    _ controller: HTTPServerController
  ) async throws -> URL {
    controller.start(bindHost: "127.0.0.1") { _ in Router() }
    return try await waitForRunningURL(controller)
  }

  // MARK: - Tests

  @Test("Initial state is .stopped with no serverURL")
  func initialState() {
    let controller = makeController()
    #expect(controller.state == .stopped)
    #expect(controller.serverURL == nil)
  }

  @Test("stop() on a fresh controller is a safe no-op")
  func stopIsIdempotent() {
    let controller = makeController()
    controller.stop()
    #expect(controller.state == .stopped)
  }

  @Test("start binds to loopback and reports .running with a real URL")
  func startBindsAndPublishesURL() async throws {
    let controller = makeController()
    let url = try await startAndAwaitRunning(controller)

    #expect(url.host == "127.0.0.1")
    #expect((url.port ?? 0) > 0)
    #expect(controller.serverURL == url)

    controller.stop()
    try await waitForStopped(controller)
  }

  @Test("stop() transitions a running controller back to .stopped")
  func stopTransitionsToStopped() async throws {
    let controller = makeController()
    _ = try await startAndAwaitRunning(controller)

    controller.stop()
    try await waitForStopped(controller)
    #expect(controller.serverURL == nil)
  }

  @Test("Restart yields a fresh port (proves the slot was released)")
  func restartYieldsFreshListener() async throws {
    let controller = makeController()

    let firstURL = try await startAndAwaitRunning(controller)
    let firstPort = firstURL.port

    // start() is documented to stop any prior listener first. Re-issuing
    // it must produce a new .running with its own bound URL — the proof
    // that the previous slot was actually released and we're not staring
    // at a cached value.
    controller.start(bindHost: "127.0.0.1") { _ in Router() }
    let secondURL = try await waitForRunningURL(
      controller, distinctFrom: firstURL)

    #expect(secondURL.host == "127.0.0.1")
    #expect((secondURL.port ?? 0) > 0)
    #expect(secondURL.port != firstPort)

    controller.stop()
    try await waitForStopped(controller)
  }

  @Test("makeRouter's boundURL provider returns nil pre-bind, the URL post-bind")
  func boundURLProviderResolvesAfterBind() async throws {
    let controller = makeController()
    let providerBox = LockedBox<(@Sendable () async -> URL?)?>(nil)

    // makeRouter runs synchronously inside start() — before the bind
    // Task is launched — so capturing here also lets us verify the
    // pre-bind contract (provider returns nil before the listener has
    // a port to advertise).
    controller.start(bindHost: "127.0.0.1") { boundURL in
      providerBox.set(boundURL)
      return Router()
    }
    let preBindProvider = providerBox.get()
    #expect(preBindProvider != nil, "makeRouter should run synchronously")
    let preBindURL = await preBindProvider?()
    #expect(preBindURL == nil, "provider must report nil before bind")

    let url = try await waitForRunningURL(controller)
    let postBindURL = await preBindProvider?()
    #expect(postBindURL == url)

    controller.stop()
    try await waitForStopped(controller)
  }

  // MARK: - Waiters

  private func waitForRunningURL(
    _ controller: HTTPServerController,
    distinctFrom previousURL: URL? = nil
  ) async throws -> URL {
    let deadline = ContinuousClock.now.advanced(by: bindTimeout)
    while ContinuousClock.now < deadline {
      switch controller.state {
      case .running(let url) where url != previousURL:
        return url
      case .failed(let message):
        Issue.record("controller failed: \(message)")
        throw CancellationError()
      case .running, .stopped:
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    Issue.record("timed out waiting for .running")
    throw CancellationError()
  }

  private func waitForStopped(
    _ controller: HTTPServerController
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: stopTimeout)
    while ContinuousClock.now < deadline {
      if controller.state == .stopped { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for .stopped")
    throw CancellationError()
  }
}

/// Lock-backed single-cell store. Used by the bound-URL-provider test
/// to ferry a value captured synchronously inside `makeRouter` back
/// out to the test body. An actor would force the capture to be `async`,
/// which `makeRouter` (called synchronously inside `start`) cannot
/// honour; a plain `let` cannot be mutated across the `Sendable`
/// boundary. A small NSLock-wrapped class threads the needle.
private final class LockedBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T
  init(_ initial: T) { self.value = initial }
  func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ newValue: T) {
    lock.lock(); defer { lock.unlock() }; value = newValue
  }
}
#endif
