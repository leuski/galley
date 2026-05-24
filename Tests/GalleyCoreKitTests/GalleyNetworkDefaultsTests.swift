import Foundation
import Testing
@testable import GalleyCoreKit

/// Tests for the `serverEndpointURL` default implementation on
/// `GalleyNetworkDefaults`. The protocol is the contract that Server,
/// Viewer, and Quicklook all reach through to discover where the
/// preview HTTP listener is bound; the URL composition matters there.
@Suite("GalleyNetworkDefaults")
struct GalleyNetworkDefaultsTests {
  /// Stand-in conformer that exists only to exercise the default
  /// `serverEndpointURL`. We don't touch UserDefaults here.
  @MainActor
  final class StubDefaults: GalleyNetworkDefaults {
    var serverHTTPPort: UInt16 = 0
    static let shared = StubDefaults()
  }

  @Test("serverEndpointURL is nil when port is zero")
  @MainActor
  func nilWhenZero() {
    let defaults = StubDefaults()
    defaults.serverHTTPPort = 0
    #expect(defaults.serverEndpointURL == nil)
  }

  @Test("serverEndpointURL composes http://127.0.0.1:<port>/ otherwise")
  @MainActor
  func composesLoopbackURL() throws {
    let defaults = StubDefaults()
    defaults.serverHTTPPort = 49_152
    let url = try #require(defaults.serverEndpointURL)
    #expect(url.scheme == "http")
    #expect(url.host == GalleyConstants.defaultHost)
    #expect(url.port == 49_152)
  }
}
