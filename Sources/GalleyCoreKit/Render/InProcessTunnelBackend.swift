import Foundation
import KosmosAppKit
import KosmosHTTPTunnel

/// `TunnelBackend` that serves the Kosmos HTTP tunnel by rendering
/// **in-process** — no loopback HTTP listener and no HTTP-server library
/// involved. It runs the shared ``PreviewRequestService``, shapes the
/// neutral ``PreviewResponse`` with ``PreviewResponseShaper`` (the same
/// shaping the FlyingFox routes apply — reload-script injection, CSP, SSE
/// framing, localized error pages), and maps the result straight onto
/// ``TunnelResponseEvent``s.
///
/// Depending only on `GalleyCoreKit` + `KosmosHTTPTunnel`, this is the
/// seam that keeps the AVP tunnel path free of `GalleyServerKit` /
/// FlyingFox: HTTP is an *optional* component for Quick Look and
/// browsers, not a dependency of the tunnel.
public final class InProcessTunnelBackend: TunnelBackend {
  private let service: PreviewRequestService
  private let watcher: DocumentWatcher
  private let shaper = PreviewResponseShaper()

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
    let shaper = self.shaper
    return AsyncThrowingStream { continuation in
      let work = Task { @MainActor in
        do {
          let path = request.path
          // `request.path` is the already-decoded URL path; the service
          // dispatches on it directly. Query lives in `request.queryItems`,
          // which the preview/template/events routes don't consult.
          let preview = await service.respond(
            path: path, origin: Self.origin(from: request))
          let shaped = shaper.shape(preview)
          continuation.yield(.head(
            status: shaped.status, headers: shaped.headers))
          switch shaped.body {
          case .bytes(let data):
            if !data.isEmpty { continuation.yield(.body(data)) }
          case .eventStream(let documentURL):
            continuation.yield(.body(PreviewSSE.connectPrelude))
            for await _ in await watcher.subscribe(to: documentURL) {
              continuation.yield(.body(PreviewSSE.reloadFrame))
            }
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
