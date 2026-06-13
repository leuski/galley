import Foundation
import GalleyCoreKit
import KosmosHTTPTunnel
import KosmosAppKit

enum Routes {
  static let assetExtensions: Set<String> = [
    "txt", "html", "htm",
    "css", "js", "json", "map",
    "svg", "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "tif",
    "woff", "woff2", "ttf", "otf",
    "mp4", "webm", "mp3", "wav", "ogg",
    "pdf"
  ]

  /// Builds the shared `Router` used by both the HTTP and HTTPS
  /// listeners. `hostURLProvider` returns the URL the request was
  /// expected to hit — used for DNS-rebinding host-header checks and
  /// for generating absolute URLs during template rewriting. It is
  /// invoked at request time because the bound port is unknown until
  /// the listener is up. `extraAllowedHostsProvider` widens the
  /// Host-header allowlist beyond the loopback aliases — used by the
  /// Kosmos bridge to admit the Mac's `.local` hostname when an AVP
  /// peer is connected. Returning an empty set keeps loopback-only.
  static func makeRouter(
    hostURLProvider: @Sendable @escaping () async -> URL?,
    extraAllowedHostsProvider: @Sendable @escaping () async -> Set<String>,
    selectedTemplateProvider: @Sendable @escaping () async -> Template,
    rendererProvider: @Sendable @escaping () async -> (any MarkdownRenderer)?,
    origin: String,
    watcher: DocumentWatcher
  ) -> Router<BasicRequestContext> {
    let router = Router<BasicRequestContext>()

    router.get("/\(RouteNames.preview)/**") { request, _ -> Response in
      await .guarded(
        request: request, hostURLProvider: hostURLProvider,
        extraAllowedHostsProvider: extraAllowedHostsProvider) { request, host in
          // For the template `origin` we use the host the request
          // actually arrived on (its `Host` header) — NOT the listener's
          // own URL, which hardcodes 127.0.0.1 and only works for
          // loopback callers. Otherwise the rendered HTML's `<base href>`
          // (and any relative asset URLs the template emits — fonts in
          // CSS, images via `url(...)`) point at 127.0.0.1 on whoever's
          // viewing, including AVP, where nothing is listening.
          await previewOrAssetResponse(
            request: request,
            hostURL: request.originURL(origin: origin, fallback: host),
            selectedTemplate: selectedTemplateProvider(),
            renderer: rendererProvider())
        }
    }

    router.get("/\(RouteNames.template)/**") { request, _ -> Response in
      await .guarded(
        request: request, hostURLProvider: hostURLProvider,
        extraAllowedHostsProvider: extraAllowedHostsProvider) { request, _ in
          await templateAssetResponse(request: request)
        }
    }

    router.get("/\(RouteNames.events)/**") { request, _ -> Response in
      await .guarded(
        request: request, hostURLProvider: hostURLProvider,
        extraAllowedHostsProvider: extraAllowedHostsProvider) { request, _ in
          eventsResponse(request: request, watcher: watcher)
        }
    }

    router.get("/") { request, _ -> Response in
      await .guarded(
        request: request, hostURLProvider: hostURLProvider,
        extraAllowedHostsProvider: extraAllowedHostsProvider) { _, _ in
            .ok("Galley Server is running.")
        }
    }

    return router
  }

  // MARK: - /preview/<path>

  private static func previewOrAssetResponse(
    request: Request,
    hostURL: URL,
    selectedTemplate: Template,
    renderer: (any MarkdownRenderer)?
  ) async -> Response {
    guard let documentURL = request.decodeFilePath(
      prefix: "/\(RouteNames.preview)")
    else {
      return .badRequest("Invalid path")
    }

    let ext = documentURL.pathExtension.lowercased()
    if MarkdownFileTypes.extensions.contains(ext) {
      guard let renderer else {
        return .errorPage(
          title: "No markdown processor configured",
          detail: """
              Install a supported processor (e.g. multimarkdown via Homebrew) \
              and pick it in Settings.
              """,
          source: "")
      }
      return await renderPreview(
        documentURL: documentURL,
        hostURL: hostURL,
        template: selectedTemplate,
        renderer: renderer)
    }
    if assetExtensions.contains(ext) {
      return serveFile(at: documentURL)
    }
    return .notFound("Unsupported extension: .\(ext)")
  }

  private static func renderPreview(
    documentURL: URL,
    hostURL: URL,
    template: Template,
    renderer: any MarkdownRenderer
  ) async -> Response {
    let source: String
    do {
      source = try String(contentsOf: documentURL, encoding: .utf8)
    } catch {
      return .notFound(
        "Cannot read \(documentURL.path): \(error.localizedDescription)")
    }

    let renderedBody: String
    do {
      renderedBody = try await renderer.render(source, baseURL: documentURL)
    } catch {
      return .errorPage(
        title: "Render error",
        detail: error.localizedDescription,
        source: source)
    }

    let composed: ComposedPreview
    do {
      composed = try template.composeHTML(
        documentContent: renderedBody,
        documentURL: documentURL,
        origin: hostURL)
    } catch {
      return .errorPage(
        title: "Template error",
        detail: """
            Cannot load template '\(template.name)': \
            \(error.localizedDescription)
            """,
        source: renderedBody)
    }

    return .ok(html: composed.html, documentURL: documentURL)
  }

  /// Serve a file's bytes. `cache` defaults to `.noStore` — correct for a
  /// document-relative asset (a live-edited sibling of the previewed file);
  /// the template-asset route passes a bounded `.maxAge` so static template
  /// files aren't re-fetched on every navigation.
  private static func serveFile(
    at url: URL, cache: CachePolicy = .noStore
  ) -> Response {
    do {
      return .data(
        try Data(contentsOf: url),
        mime: MIMETypes.mimeType(for: url),
        cacheControl: cache.cacheControl)
    } catch {
      return .notFound(error.localizedDescription)
    }
  }

  // MARK: - /template/<id>/<file>

  private static func templateAssetResponse(
    request: Request
  ) async -> Response {
    guard case .templateAsset(let templateID, let file)
            = PreviewRoute(path: request.uri.path)
    else {
      return .badRequest("Invalid template asset path")
    }
    guard let template = await TemplateStore.shared
      .existingTemplate(forID: templateID)
    else {
      return .notFound("Template not found: \(templateID)")
    }
    guard let assetURL = template.resolveAsset(file: file) else {
      return .notFound("No such asset in template '\(template.name)': \(file)")
    }
    return serveFile(
      at: assetURL,
      cache: PreviewRoute.templateAsset(id: templateID, file: file).cachePolicy)
  }

  // MARK: - /events/<path> (SSE)

  private static func eventsResponse(
    request: Request,
    watcher: DocumentWatcher
  ) -> Response {
    guard
      let documentURL = request.decodeFilePath(prefix: "/\(RouteNames.events)"),
      MarkdownFileTypes.extensions.contains(
        documentURL.pathExtension.lowercased())
    else {
      return .badRequest("Invalid event path")
    }

    return .events { await watcher.subscribe(to: documentURL) }
  }

}
