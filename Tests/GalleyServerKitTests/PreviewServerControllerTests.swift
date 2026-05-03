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

  @Test("Starting with a non-IPv4 host fails synchronously")
  func nonNumericHostFails() {
    let controller = makeController()
    controller.start(url: URL(string: "http://example.com:8089/")!)
    if case .failed = controller.state {
      // expected — sockaddr_in.inet rejects DNS-style hosts
    } else {
      Issue.record(
        "Expected .failed for non-IPv4 host, got \(controller.state)")
    }
    #expect(controller.serverURL == nil)
  }

  @Test("stop() resets state to .stopped from any state")
  func stopResetsState() {
    let controller = makeController()
    controller.start(url: URL(string: "http://example.com:8089/")!)
    // controller is now .failed — verify stop() returns it to .stopped
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
