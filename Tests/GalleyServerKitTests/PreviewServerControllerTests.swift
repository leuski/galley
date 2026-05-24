#if os(macOS)
import Foundation
import Testing
import GalleyCoreKit
@testable import GalleyServerKit

@Suite("PreviewServerController")
@MainActor
struct PreviewServerControllerTests {
  private func makeController() -> PreviewServerController {
    PreviewServerController(
      selectedTemplateProvider: { Template.default },
      rendererProvider: { nil })
  }

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
    #expect(controller.serverURL == nil)
  }

  @Test("State enum equates by associated value")
  func stateEquatable() {
    let url = URL(string: "http://127.0.0.1:8089/")!
    #expect(PreviewServerController.State.stopped
            == PreviewServerController.State.stopped)
    #expect(PreviewServerController.State.running(url: url)
            == PreviewServerController.State.running(url: url))
    #expect(PreviewServerController.State.failed(message: "x")
            != PreviewServerController.State.failed(message: "y"))
  }
}
#endif
