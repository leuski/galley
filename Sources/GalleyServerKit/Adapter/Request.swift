import Foundation
import HTTPTypes

// Hummingbird-shaped request view for the kit's call sites. Exposes the
// three surfaces `Routes.swift` actually reads: `uri.path`, `head.authority`
// (HTTP/1.1 Host header surfaced as Hummingbird's `authority`), and a
// `headers: HTTPFields` dictionary keyed by `HTTPField.Name`. The
// `HTTPFields` type is kept (swift-http-types is a tiny zero-dependency
// package) so callers continue to use `headers[.contentType]` /
// `[.secFetchSite]` unchanged.
struct Request: Sendable {
  struct URI: Sendable {
    let path: String
  }

  struct Head: Sendable {
    /// Hummingbird's term for the HTTP/1.1 Host header — surfaced here
    /// from FlyingFox's `headers[.host]` at dispatch.
    let authority: String?
  }

  let uri: URI
  let head: Head
  let headers: HTTPFields
}
