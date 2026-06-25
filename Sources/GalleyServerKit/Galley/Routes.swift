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
  /// `Response`. SSE wires the `DocumentWatcher` subscription here;
  /// structured failures become localized error pages. Internal (not
  /// private) so `InProcessTunnelBackend` builds the *same* `Response`
  /// and serializes it over the Kosmos tunnel — one source of truth for
  /// reload-injection, CSP, SSE framing, and error pages.
  static func response(
    from preview: PreviewResponse, watcher: DocumentWatcher
  ) -> Response {
    switch preview {
    case .html(let html, let documentURL):
      return .ok(html: html, documentURL: documentURL)
    case .bytes(let resolved):
      return .data(
        resolved.data,
        mime: resolved.mime,
        cacheControl: resolved.cache.cacheControl)
    case .events(let documentURL):
      return .events { await watcher.subscribe(to: documentURL) }
    case .plainText(let text):
      return .ok("\(text)")
    case .badRequest(let message):
      return .badRequest("\(message)")
    case .notFound(let message):
      return .notFound("\(message)")
    case .failure(let failure):
      return errorResponse(failure)
    }
  }

  private static func errorResponse(_ failure: PreviewFailure) -> Response {
    switch failure {
    case .noProcessor:
      return .errorPage(
        title: "No markdown processor configured",
        detail: """
            Install a supported processor (e.g. multimarkdown via Homebrew) \
            and pick it in Settings.
            """,
        source: "")
    case .render(let detail, let source):
      return .errorPage(title: "Render error", detail: detail, source: source)
    case .template(let name, let detail, let source):
      return .errorPage(
        title: "Template error",
        detail: "Cannot load template '\(name)': \(detail)",
        source: source)
    }
  }
}
