import Foundation
import Observation
import OSLog
import GalleyCoreKit
import KosmosHTTPTunnel

private let log = Logger(
  subsystem: bundleIdentifier, category: "PreviewServer")

/// Galley-specific facade over the generic `HTTPServerController`,
/// adopting GalleyCoreKit's `PreviewHTTPListener` so the Server can drive
/// it without importing this framework. It carries no render config of
/// its own: `start(service:watcher:host:)` receives the
/// `PreviewRequestService` + `DocumentWatcher` from the Server (the same
/// instances that feed the Kosmos tunnel), builds the router via
/// `Routes.makeRouter(...)`, and delegates the lifecycle (state machine,
/// bound-URL publication, start/stop) to the generic controller.
///
/// Loopback-only by design. Same-machine consumers (Quick Look,
/// browsers, BBEdit) reach the listener via `127.0.0.1`. AVP doesn't dial
/// it — it tunnels each request over Kosmos and renders in-process. No
/// HTTPS, no cert provisioning.
@Observable
@MainActor
public final class PreviewServerController: PreviewHTTPListener {
  @ObservationIgnored
  private let http = HTTPServerController()

  public init() {}

  /// State + URL forwarders. Reading these inside an observer scope
  /// registers a dependency on the inner controller's `state`, so
  /// SwiftUI views that observe the facade still see invalidations
  /// when the listener transitions.
  public var state: PreviewHTTPListenerState { http.state.asListenerState }
  public var stateChanges: AsyncStream<PreviewHTTPListenerState> {
    let upstream = http.stateChanges
    return AsyncStream { continuation in
      let task = Task {
        for await state in upstream {
          continuation.yield(state.asListenerState)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Starts the loopback HTTP listener. AVP traffic doesn't reach the
  /// listener directly — it tunnels over Kosmos and renders in-process.
  public func start(
    service: PreviewRequestService, watcher: DocumentWatcher, host: String
  ) {
    http.start(bindHost: host) { boundURL in
      Routes.makeRouter(
        hostURLProvider: boundURL,
        extraAllowedHostsProvider: { [] },
        service: service,
        origin: TunnelHeaders.origin,
        watcher: watcher)
    }
  }

  public func stop() {
    http.stop()
  }
}

extension HTTPServerState {
  /// Project the generic server state onto the public listener contract.
  var asListenerState: PreviewHTTPListenerState {
    switch self {
    case .stopped: .stopped
    case .running(let url): .running(url)
    case .failed(let message): .failed(message)
    }
  }
}

/// ObjC-discoverable factory the Server resolves by name
/// (`NSClassFromString`) so it can use the HTTP listener without a
/// compile-time dependency on this framework.
@objc(GalleyPreviewHTTPListenerFactory)
public final class GalleyPreviewHTTPListenerFactory: NSObject,
  PreviewHTTPListenerFactory {
  @MainActor public static func makeListener() -> AnyObject {
    PreviewServerController()
  }
}
