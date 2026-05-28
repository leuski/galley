#if os(macOS)
import Foundation
import HTTPTypes
import Testing
import FlyingFox
@testable import GalleyServerKit

/// Verifies that every `HTTPTypes.HTTPResponse.Status` the kit's call sites actually
/// build maps to a `HTTPStatusCode` with the matching numeric code. We
/// don't compare reason phrases — FlyingFox's catalogue and HTTPTypes' may
/// drift on wording; the wire-meaningful part is the integer code.
@Suite("Adapter/Status mapping")
struct AdapterStatusMappingTests {
  @Test(
    "Each Status used by the kit maps to the same numeric code",
    arguments: [
      (HTTPTypes.HTTPResponse.Status.ok,                  200),
      (HTTPTypes.HTTPResponse.Status.badRequest,          400),
      (HTTPTypes.HTTPResponse.Status.forbidden,           403),
      (HTTPTypes.HTTPResponse.Status.notFound,            404),
      (HTTPTypes.HTTPResponse.Status.serviceUnavailable,  503),
      (HTTPTypes.HTTPResponse.Status.internalServerError, 500)
    ])
  func mapsToSameNumericCode(_ status: HTTPTypes.HTTPResponse.Status, expected: Int) {
    let code = flyingFoxStatus(from: status)
    #expect(code.code == expected)
  }
}
#endif
