#if os(macOS)
import Foundation
import Testing
@testable import GalleyServerKit

@Suite("HostHeaderGuard")
struct HostHeaderGuardTests {
  @Test("127.0.0.1 with matching port is allowed")
  func loopbackIPv4Allowed() {
    #expect(Routes.isHostAllowed("127.0.0.1:8089", expectedPort: 8089))
  }

  @Test("localhost with matching port is allowed")
  func localhostAllowed() {
    #expect(Routes.isHostAllowed("localhost:8089", expectedPort: 8089))
  }

  @Test("IPv6 loopback with matching port is allowed")
  func loopbackIPv6Allowed() {
    #expect(Routes.isHostAllowed("[::1]:8089", expectedPort: 8089))
  }

  @Test("Host case is normalized")
  func caseInsensitive() {
    #expect(Routes.isHostAllowed("LocalHost:8089", expectedPort: 8089))
  }

  @Test("Surrounding whitespace is trimmed")
  func trimsWhitespace() {
    #expect(Routes.isHostAllowed("  127.0.0.1:8089 ", expectedPort: 8089))
  }

  @Test("Default port 80 is assumed when the header omits a port")
  func defaultPortWhenOmitted() {
    #expect(Routes.isHostAllowed("127.0.0.1", expectedPort: 80))
    #expect(!Routes.isHostAllowed("127.0.0.1", expectedPort: 8089))
  }

  @Test("Mismatched port is rejected")
  func wrongPort() {
    #expect(!Routes.isHostAllowed("127.0.0.1:9999", expectedPort: 8089))
  }

  @Test("Non-loopback hosts are rejected (DNS-rebinding defence)")
  func nonLoopbackRejected() {
    #expect(!Routes.isHostAllowed("example.com:8089", expectedPort: 8089))
    #expect(!Routes.isHostAllowed("10.0.0.1:8089", expectedPort: 8089))
  }

  @Test("Empty header is rejected")
  func emptyRejected() {
    #expect(!Routes.isHostAllowed("", expectedPort: 8089))
    #expect(!Routes.isHostAllowed("   ", expectedPort: 8089))
  }
}
#endif
