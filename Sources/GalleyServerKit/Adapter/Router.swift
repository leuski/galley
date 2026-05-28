import Foundation

// Hummingbird-shaped router. The shim only needs the surface the kit's
// own routes use: `Router()` with the default `BasicRequestContext`, and
// `.get(pattern) { request, context -> Response in ... }` registration.
//
// We deliberately do NOT delegate matching to FlyingFox's `HTTPRoute`:
// FlyingFox's `*` is single-segment, whereas every route the kit
// registers uses `/**` to match an arbitrary tail (`/preview/**`,
// `/template/**`, `/events/**`). Mirroring Hummingbird's matching
// ourselves here is the entire reason this layer exists.

/// Marker type matching Hummingbird's empty context shape so call sites
/// can write `Router<BasicRequestContext>` / `Router()` verbatim.
struct BasicRequestContext: Sendable {}

/// Hummingbird's `/path/**` style matcher. FlyingFox's HTTPRoute matcher
/// would not preserve the kit's existing patterns — see file header.
struct PathPattern: Sendable, Equatable {
  enum Mode: Sendable, Equatable {
    /// Matches the prefix exactly. Used for `/` and any future
    /// non-wildcard pattern.
    case exact
    /// Matches the prefix verbatim OR the prefix followed by `/` and an
    /// arbitrary, possibly multi-segment, tail.
    case multiSegmentWildcard
  }

  let prefix: String
  let mode: Mode

  init(_ pattern: String) {
    if pattern.hasSuffix("/**") {
      self.prefix = String(pattern.dropLast(3))
      self.mode = .multiSegmentWildcard
    } else {
      self.prefix = pattern
      self.mode = .exact
    }
  }

  func matches(_ path: String) -> Bool {
    switch mode {
    case .exact:
      return path == prefix
    case .multiSegmentWildcard:
      if path == prefix { return true }
      // The trailing `/` matters: `/previewother` shares a string prefix
      // with `/preview` but is a different first segment and must NOT
      // match `/preview/**`.
      return path.hasPrefix(prefix + "/")
    }
  }
}

/// Hummingbird's `Router<Context>` minus the middleware stack — the kit
/// doesn't register any middleware, so the type parameter exists purely
/// for call-site signature parity (`Router<BasicRequestContext>`).
///
/// Routes are matched in registration order. The first pattern whose
/// `matches(_:)` returns true is dispatched; no match yields a 404.
final class Router<Context: Sendable>: @unchecked Sendable {
  typealias Handler = @Sendable (Request, Context) async throws -> Response

  struct Route: Sendable {
    let method: HTTPRequestMethod
    let pattern: PathPattern
    let handler: Handler
  }

  enum HTTPRequestMethod: Sendable {
    case get
  }

  private(set) var routes: [Route] = []

  init() {}

  func get(
    _ pattern: String,
    _ handler: @escaping Handler
  ) {
    routes.append(
      Route(
        method: .get,
        pattern: PathPattern(pattern),
        handler: handler))
  }

  /// Pure matcher used by the dispatcher. Returns nil when no route
  /// matches, so the dispatcher can synthesize a 404.
  func route(forGetPath path: String) -> Route? {
    for route in routes
    where route.method == .get && route.pattern.matches(path) {
      return route
    }
    return nil
  }
}
