#if os(visionOS)
import ALFoundation
import Foundation
import GalleyCoreKit
import WebKit

/// SwiftUI `URLSchemeHandler` for the `galley://` scheme on AVP.
///
/// Every request WebKit makes on a `galley://...` URL is wrapped as a
/// `ProxyHTTPRequest` Kosmos broadcast and tunneled to the Mac, which
/// resolves it against its loopback HTTP listener and streams the
/// response back as chunks. This is the AVP side of the data plane;
/// the actual request/response routing lives in `HTTPTunnelAVPClient`.
///
/// Constructed once per `DocumentModel`. The reference to the shared
/// `HTTPTunnelAVPClient` is captured strongly here and held weakly by
/// the client's response-routing entries, so a transient `WebPage`
/// teardown doesn't leak.
@MainActor
struct KosmosTunnelSchemeHandler: URLSchemeHandler {
  /// Force-unwrap is safe — `KosmosTunnelScheme.name` is a constant
  /// string that's guaranteed to satisfy `URLScheme`'s validation
  /// (alphanumeric + dash, lowercase ASCII).
  static let scheme = URLScheme(KosmosTunnelScheme.name)
  !! "Failed to make URLScheme for \(KosmosTunnelScheme.name)"

  let tunnel: HTTPTunnelAVPClient

  nonisolated
  func reply(
    for request: URLRequest
  ) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task { @MainActor in
        let stream = tunnel.openTunnel(for: request)
        do {
          for try await result in stream {
            continuation.yield(result)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
#endif
