#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

@Suite("BindWatchdog")
struct BindWatchdogTests {
  /// Production HTTPS-listener path: `app.run()` enters its bind-and-
  /// serve loop and (on success) `onServerRunning` fires with the
  /// bound channel. Watchdog turns "did onServerRunning fire?" into
  /// an awaitable signal, so a silent hang surfaces as a loud log.
  @Test("signal() before wait() resolves immediately as bound")
  func signalThenWait() async {
    let watchdog = BindWatchdog()
    await watchdog.signal()
    let bound = await watchdog.wait(deadline: .milliseconds(500))
    #expect(bound, "Watchdog should report bound when already signaled")
  }

  @Test("signal() during wait() resolves before the deadline")
  func signalRacesWait() async {
    let watchdog = BindWatchdog()
    Task {
      try? await Task.sleep(for: .milliseconds(20))
      await watchdog.signal()
    }
    let bound = await watchdog.wait(deadline: .seconds(2))
    #expect(bound, "Signal mid-wait should resolve as bound")
  }

  @Test("no signal before deadline → reports not bound")
  func timeout() async {
    let watchdog = BindWatchdog()
    let bound = await watchdog.wait(deadline: .milliseconds(80))
    #expect(!bound, """
      Watchdog should report not-bound on deadline. This is the \
      production silent-hang case: app.run() entered but \
      onServerRunning never fired (`::` LAN bind today).
      """)
  }

  @Test("signal() after timeout doesn't retroactively change result")
  func lateSignalIgnored() async {
    let watchdog = BindWatchdog()
    let bound = await watchdog.wait(deadline: .milliseconds(40))
    await watchdog.signal()
    #expect(!bound)
    // A subsequent wait sees the signal — internal flag persists.
    let later = await watchdog.wait(deadline: .milliseconds(40))
    #expect(later)
  }

  @Test("multiple signals are idempotent")
  func multipleSignalsIdempotent() async {
    let watchdog = BindWatchdog()
    await watchdog.signal()
    await watchdog.signal()
    await watchdog.signal()
    let bound = await watchdog.wait(deadline: .milliseconds(40))
    #expect(bound)
  }

  /// Pins the Swift Concurrency contract the HTTPS run-task fall-through
  /// relies on: when a Task is cancelled while suspended on an awaitable
  /// that does *not* throw on cancel (Hummingbird's `app.run()` is built
  /// on swift-service-lifecycle, which returns normally on cooperative
  /// shutdown rather than throwing `CancellationError`), the resumed
  /// body still sees `Task.isCancelled == true`. The HTTPS run task
  /// uses this flag to skip the port-file clear, so the replacement
  /// listener spawned by `start()` keeps its freshly-written port.
  @Test("Task.isCancelled is true after cooperative cancellation")
  func taskIsCancelledAfterCooperativeCancel() async {
    let observed = await withCheckedContinuation { cont in
      let task = Task<Bool, Never> {
        // Suspend on a non-throwing awaitable. Cancel hits us here.
        try? await Task.sleep(for: .seconds(60))
        return Task.isCancelled
      }
      Task {
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let value = await task.value
        cont.resume(returning: value)
      }
    }
    #expect(observed, """
      Cooperative cancellation must surface via Task.isCancelled even \
      when the awaited operation returned normally instead of throwing.
      """)
  }
}
#endif
