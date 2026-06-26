#if os(macOS)
import Foundation
import Testing
import GalleyCoreKit
@testable import GalleyServerKit

@Suite("PreviewServerController")
@MainActor
struct PreviewServerControllerTests {
  private func makeController() -> PreviewServerController {
    PreviewServerController()
  }

  @Test("Initial state is .stopped")
  func initialState() {
    let controller = makeController()
    #expect(controller.state == .stopped)
  }

  @Test("stop() on a fresh controller is a safe no-op")
  func stopIsIdempotent() {
    let controller = makeController()
    controller.stop()
    #expect(controller.state == .stopped)
  }

  /// Pins the Swift Concurrency contract the HTTP/HTTPS run tasks
  /// rely on: when a Task is cancelled while suspended on an
  /// awaitable that does *not* throw on cancel (Hummingbird's
  /// `app.run()` is built on swift-service-lifecycle, which returns
  /// normally on cooperative shutdown rather than throwing
  /// `CancellationError`), the resumed body still sees
  /// `Task.isCancelled == true`. The run tasks use this flag to skip
  /// the port-file clear so the replacement listener spawned by
  /// `start()` keeps its freshly-written port.
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
