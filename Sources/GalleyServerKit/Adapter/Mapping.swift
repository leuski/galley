import Foundation
import HTTPTypes
import FlyingFox

// Header and status translation between the swift-http-types vocabulary
// the kit's call sites use (HTTPField.Name / HTTPFields / HTTPResponse.Status)
// and the FlyingFox vocabulary the underlying server speaks
// (HTTPHeader / HTTPHeaders / HTTPStatusCode).
//
// FlyingFox's `HTTPHeader` is case-insensitive (its `Hashable` /
// `Equatable` lowercase the raw value), so the round-trip preserves
// subscript lookups by canonical name even though the wire-side casing
// is whatever the request actually arrived with.

/// FlyingFox HTTPHeaders → swift-http-types HTTPFields. Silently drops
/// any header whose name fails RFC validation in HTTPField.Name — the
/// kit only reads a handful of well-known headers, so a malformed
/// custom header just becomes invisible to the routes (matches what
/// Hummingbird would have done with the same input).
func toHTTPFields(_ headers: HTTPHeaders) -> HTTPFields {
  var result = HTTPFields()
  for (header, value) in headers {
    guard let name = HTTPField.Name(header.rawValue) else { continue }
    result[name] = value
  }
  return result
}

/// swift-http-types HTTPFields → FlyingFox HTTPHeaders. Used when
/// emitting response headers. The destination type is
/// `[HTTPHeader: String]`; each `HTTPField.Name` is forwarded through
/// `HTTPHeader(_:)` (a String wrapper, no validation).
func toFlyingFoxHeaders(_ fields: HTTPFields) -> HTTPHeaders {
  var result: HTTPHeaders = [:]
  for field in fields {
    result[HTTPHeader(field.name.rawName)] = field.value
  }
  return result
}

/// swift-http-types HTTPResponse.Status → FlyingFox HTTPStatusCode. The
/// numeric code is the wire-meaningful part; the reason phrase is taken
/// from the source `Status` so the rendered response reads identically
/// to what Hummingbird would have produced.
func flyingFoxStatus(
  from status: HTTPTypes.HTTPResponse.Status
) -> HTTPStatusCode {
  HTTPStatusCode(status.code, phrase: status.reasonPhrase)
}
