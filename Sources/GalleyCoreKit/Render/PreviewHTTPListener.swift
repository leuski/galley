import Foundation
import KosmosAppKit

/// State of the optional loopback HTTP preview listener, mirrored to the
/// menu bar and used to publish `serverHTTPPort`.
public enum PreviewHTTPListenerState: Sendable, Equatable {
  case stopped
  case running(URL)
  case failed(String)
}

/// Contract for the **optional** loopback HTTP preview server — the
/// component that lets Quick Look and browsers fetch the same rendered
/// preview over `http://127.0.0.1:<port>`. The concrete implementation
/// lives in `GalleyServerKit` (FlyingFox); the Server discovers it at
/// runtime via ``discoverPreviewHTTPListener()`` and drives it through
/// this protocol, so **no app code imports `GalleyServerKit`**. When the
/// implementation isn't present, the Server runs without an HTTP listener
/// and Quick Look falls back to its in-process render.
///
/// Inputs are transport-neutral GalleyCoreKit/KosmosAppKit types
/// (`PreviewRequestService`, `DocumentWatcher`), so the same render
/// config + file watch that feed the Kosmos tunnel also feed this
/// listener — neither depends on the other.
@MainActor
public protocol PreviewHTTPListener: AnyObject, Sendable {
  /// Bind the loopback listener and begin serving `service`'s preview
  /// routes, sourcing live-reload events from `watcher`. `host` is the
  /// loopback bind host (e.g. `127.0.0.1`).
  func start(service: PreviewRequestService, watcher: DocumentWatcher,
             host: String)
  func stop()
  var state: PreviewHTTPListenerState { get }
  var stateChanges: AsyncStream<PreviewHTTPListenerState> { get }
}

/// ObjC-discoverable factory the Server resolves by name. A Swift type in
/// an optionally-linked module can't be named at compile time without
/// importing it, so the seam crosses through the ObjC runtime: the
/// implementation registers an `@objc` class conforming to this, and the
/// Server looks it up with `NSClassFromString`. `makeListener()` returns
/// an `AnyObject` the caller casts to ``PreviewHTTPListener``.
@objc public protocol PreviewHTTPListenerFactory {
  @MainActor static func makeListener() -> AnyObject
}

/// The well-known ObjC class name the implementation registers under.
/// `GalleyServerKit` exposes a `@objc(GalleyPreviewHTTPListenerFactory)`
/// class conforming to ``PreviewHTTPListenerFactory``.
private let factoryClassName = "GalleyPreviewHTTPListenerFactory"

/// Resolve the optional HTTP preview listener at runtime. Returns `nil`
/// when `GalleyServerKit` is not loaded into the process — the caller
/// then runs without an HTTP listener (Quick Look renders in-process).
@MainActor
public func discoverPreviewHTTPListener() -> (any PreviewHTTPListener)? {
  resolvePreviewHTTPListener(className: factoryClassName)
}

/// Name-parameterized core of ``discoverPreviewHTTPListener()``.
/// Internal so tests can drive both the present path (the real class)
/// and the absent path (a bogus name) without unloading frameworks.
@MainActor
func resolvePreviewHTTPListener(
  className: String
) -> (any PreviewHTTPListener)? {
  guard
    let factory = NSClassFromString(className)
      as? any PreviewHTTPListenerFactory.Type
  else { return nil }
  return factory.makeListener() as? any PreviewHTTPListener
}
