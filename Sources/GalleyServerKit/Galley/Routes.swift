import Foundation
import GalleyCoreKit
import KosmosHTTPTunnel

enum Routes {
  /// Builds the shared `Router`. `hostURLProvider` returns the URL the
  /// request was expected to hit — used for DNS-rebinding host-header
  /// checks. It is invoked at request time because the bound port is
  /// unknown until the listener is up. `extraAllowedHostsProvider` widens
  /// the Host-header allowlist beyond the loopback aliases — used by the
  /// Kosmos bridge to admit the Mac's `.local` hostname when an AVP peer
  /// is connected. Returning an empty set keeps loopback-only.
  ///
  /// The actual request handling (render / asset / template / events) is
  /// the transport-neutral `PreviewRequestService`; this router is just
  /// the FlyingFox adapter — host-guarding, origin computation, and
  /// mapping `PreviewResponse` onto FlyingFox `Response`.
  static func makeRouter(
    hostURLProvider: @Sendable @escaping () async -> URL?,
    extraAllowedHostsProvider: @Sendable @escaping () async -> Set<String>,
    selectedTemplateProvider: @Sendable @escaping () async -> Template,
    rendererProvider: @Sendable @escaping () async -> (any MarkdownRenderer)?,
    origin: String,
    watcher: DocumentWatcher
  ) -> Router<BasicRequestContext> {
    let router = Router<BasicRequestContext>()
    let service = PreviewRequestService(
      selectedTemplate: selectedTemplateProvider,
      renderer: rendererProvider)

    // Every route runs through the same host-guard + service dispatch.
    // For the template `origin` we use the host the request actually
    // arrived on (its `Host` header) — NOT the listener's own URL, which
    // hardcodes 127.0.0.1 and only works for loopback callers. Otherwise
    // the rendered HTML's `<base href>` (and any relative asset URLs the
    // template emits — fonts in CSS, images via `url(...)`) point at
    // 127.0.0.1 on whoever's viewing, including AVP, where nothing is
    // listening.
    @Sendable func handle(_ request: Request) async -> Response {
      await .guarded(
        request: request, hostURLProvider: hostURLProvider,
        extraAllowedHostsProvider: extraAllowedHostsProvider) { request, host in
          let preview = await service.respond(
            path: request.uri.path,
            origin: request.originURL(origin: origin, fallback: host))
          return response(from: preview, watcher: watcher)
        }
    }

    router.get("/\(RouteNames.preview)/**") { request, _ in
      await handle(request)
    }
    router.get("/\(RouteNames.template)/**") { request, _ in
      await handle(request)
    }
    router.get("/\(RouteNames.events)/**") { request, _ in
      await handle(request)
    }
    router.get("/") { request, _ in await handle(request) }

    return router
  }

  /// Map a transport-neutral `PreviewResponse` onto a FlyingFox
  /// `Response`. All response *shaping* — reload-script injection, CSP,
  /// asset headers, SSE framing, localized error pages — lives in
  /// `GalleyCoreKit`'s `PreviewResponseShaper`, so this is a thin adapter
  /// that copies the shaped status/headers/bytes onto FlyingFox and wires
  /// the `DocumentWatcher` subscription for the SSE stream. The Kosmos
  /// tunnel's `InProcessTunnelBackend` shapes the *same* `ShapedResponse`
  /// without FlyingFox, so both carriers emit byte-identical output.
  static func response(
    from preview: PreviewResponse, watcher: DocumentWatcher
  ) -> Response {
    let shaped = PreviewResponseShaper().shape(preview)
    switch shaped.body {
    case .bytes(let data):
      return Response(
        status: shaped.status,
        headerPairs: shaped.headers,
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    case .eventStream(let documentURL):
      return Response(
        status: shaped.status,
        headerPairs: shaped.headers,
        body: ResponseBody { writer in
          try await writer.write(ByteBuffer(bytes: PreviewSSE.connectPrelude))
          for await _ in await watcher.subscribe(to: documentURL) {
            try await writer.write(ByteBuffer(bytes: PreviewSSE.reloadFrame))
          }
          try await writer.finish(nil)
        })
    }
  }
}
