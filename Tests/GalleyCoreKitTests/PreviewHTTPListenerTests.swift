import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("PreviewHTTPListener discovery")
struct PreviewHTTPListenerTests {
  @MainActor
  @Test("resolution returns nil for an unregistered factory class")
  func resolutionAbsent() {
    // No such ObjC class → the HTTP feature reads as absent and the
    // caller renders in-process.
    #expect(resolvePreviewHTTPListener(
      className: "NoSuchPreviewHTTPListenerFactory") == nil)
  }

//  @MainActor
//  @Test("discovery resolves the GalleyServerKit factory when loaded")
//  func discoveryPresent() {
//    // The unified test bundle links GalleyServerKit, so the @objc
//    // factory is registered: discovery must find it, construct a
//    // listener via the ObjC-runtime seam, and hand back a usable,
//    // initially-stopped PreviewHTTPListener.
//    let listener = discoverPreviewHTTPListener()
//    #expect(listener != nil)
//    #expect(listener?.state == .stopped)
//  }

  @Test("listener state is value-equatable")
  func stateEquatable() {
    let url = URL(fileURLWithPath: "/x")
    #expect(PreviewHTTPListenerState.stopped == .stopped)
    #expect(PreviewHTTPListenerState.running(
      URL(string: "http://127.0.0.1:1/")!)
      != .running(url))
    #expect(PreviewHTTPListenerState.failed("a") != .failed("b"))
  }
}
