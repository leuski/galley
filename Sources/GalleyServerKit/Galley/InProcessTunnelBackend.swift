import Foundation
import GalleyCoreKit
import KosmosCore
import KosmosHTTPTunnel

/// `TunnelBackend` that serves the Kosmos HTTP tunnel by rendering
/// **in-process** — no loopback HTTP listener involved. It runs the
/// shared `PreviewRequestService`, maps the neutral `PreviewResponse`
/// onto the *same* FlyingFox `Response` the HTTP routes build
/// (`Routes.response(from:watcher:)`), and serializes that `Response`
/// into `TunnelResponseEvent`s.
///
/// Building the real `Response` and draining it — rather than
/// re-deriving status/headers/body — keeps one source of truth for
/// reload-script injection, CSP, SSE framing, and localized error
/// pages: AVP and Quick Look over the tunnel see exactly what a
/// loopback HTTP caller would.
public final class InProcessTunnelBackend: TunnelBackend {
  private let service: PreviewRequestService
  private let watcher: DocumentWatcher

  public init(service: PreviewRequestService, watcher: DocumentWatcher) {
    self.service = service
    self.watcher = watcher
  }

  @MainActor
  public func resolve(
    _ request: ProxyHTTPRequest
  ) -> AsyncThrowingStream<TunnelResponseEvent, any Error> {
    let service = self.service
    let watcher = self.watcher
    return AsyncThrowingStream { continuation in
      let work = Task { @MainActor in
        do {
          // `urlPath` is percent-encoded path + optional query; the
          // service dispatches on the path and decodes internally.
          let path = String(request.urlPath.prefix { $0 != "?" })
          let preview = await service.respond(
            path: path, origin: Self.origin(from: request))
          let response = Routes.response(from: preview, watcher: watcher)
          continuation.yield(.head(
            status: response.statusCode,
            headers: response.headerPairs))
          try await response.drainBody { data in
            continuation.yield(.body(data))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in work.cancel() }
    }
  }

  /// The `<base href>` origin for rendered HTML: the AVP scheme handler
  /// stamps `X-Kosmos-Origin` (`TunnelHeaders.origin`); fall back to the
  /// scheme origin when absent so sub-resource fetches stay on the
  /// tunnel.
  private static func origin(from request: ProxyHTTPRequest) -> URL {
    let header = request.headers.first {
      $0.key.caseInsensitiveCompare(TunnelHeaders.origin) == .orderedSame
    }?.value
    if let header, let url = URL(string: header) { return url }
    return TunnelScheme.originURL
  }
}
