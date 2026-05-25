import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import Security
import GalleyCoreKit
import KosmosHTTPTunnel

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
    watcher: DocumentWatcher
  ) -> Router<BasicRequestContext> {
    let router = Router()

    router.get("/\(RouteNames.preview)/**") { request, _ -> Response in
      guard let hostURL = await hostURLProvider() else {
        return HTTPResponses.unavailable()
      }
      if let denied = guardRequest(
        request, hostURL: hostURL,
        extra: await extraAllowedHostsProvider())
      {
        return denied
      }
      // For the template `origin` we use the host the request
      // actually arrived on (its `Host` header) — NOT the listener's
      // own URL, which hardcodes 127.0.0.1 and only works for
      // loopback callers. Otherwise the rendered HTML's `<base href>`
      // (and any relative asset URLs the template emits — fonts in
      // CSS, images via `url(...)`) point at 127.0.0.1 on whoever's
      // viewing, including AVP, where nothing is listening.
      let originURL = templateOriginURL(for: request, fallback: hostURL)
      return await previewOrAssetResponse(
        request: request,
        hostURL: originURL,
        selectedTemplate: await selectedTemplateProvider(),
        renderer: await rendererProvider())
    }

    router.get("/\(RouteNames.template)/**") { request, _ -> Response in
      guard let hostURL = await hostURLProvider() else {
        return HTTPResponses.unavailable()
      }
      if let denied = guardRequest(
        request, hostURL: hostURL,
        extra: await extraAllowedHostsProvider())
      {
        return denied
      }
      return await templateAssetResponse(request: request)
    }

    router.get("/\(RouteNames.events)/**") { request, _ -> Response in
      guard let hostURL = await hostURLProvider() else {
        return HTTPResponses.unavailable()
      }
      if let denied = guardRequest(
        request, hostURL: hostURL,
        extra: await extraAllowedHostsProvider())
      {
        return denied
      }
      return eventsResponse(request: request, watcher: watcher)
    }

    router.get("/") { request, _ -> Response in
      guard let hostURL = await hostURLProvider() else {
        return HTTPResponses.unavailable()
      }
      if let denied = guardRequest(
        request, hostURL: hostURL,
        extra: await extraAllowedHostsProvider())
      {
        return denied
      }
      return Response(
        status: .ok,
        headers: [.contentType: "text/plain; charset=utf-8"],
        body: ResponseBody(
          byteBuffer: ByteBuffer(string: "Galley Server is running.\n")))
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
    guard let documentURL = decodeFilePath(
      from: request.uri.path, prefix: "/\(RouteNames.preview)")
    else {
      return HTTPResponses.badRequest(
        String(localized: "Invalid path", bundle: .galleyServerKit))
    }

    let ext = documentURL.pathExtension.lowercased()
    if MarkdownFileTypes.extensions.contains(ext) {
      guard let renderer else {
        return HTTPResponses.errorPage(
          title: String(
            localized: "No markdown processor configured",
            bundle: .galleyServerKit),
          detail: String(
            localized: """
              Install a supported processor (e.g. multimarkdown via Homebrew) \
              and pick it in Settings.
              """,
            bundle: .galleyServerKit),
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
    return HTTPResponses.notFound(
      String(
        localized: "Unsupported extension: .\(ext)",
        bundle: .galleyServerKit))
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
      return HTTPResponses.notFound(
        String(
          localized:
            "Cannot read \(documentURL.path): \(error.localizedDescription)",
          bundle: .galleyServerKit))
    }

    let renderedBody: String
    do {
      renderedBody = try await renderer.render(source, baseURL: documentURL)
    } catch {
      return HTTPResponses.errorPage(
        title: String(localized: "Render error", bundle: .galleyServerKit),
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
      return HTTPResponses.errorPage(
        title: String(localized: "Template error", bundle: .galleyServerKit),
        detail: String(
          localized: """
            Cannot load template '\(template.name)': \
            \(error.localizedDescription)
            """,
          bundle: .galleyServerKit),
        source: renderedBody)
    }
    let substituted = composed.html
    let nonce = generateNonce()
    let withReload = injectReloadScript(
      into: substituted, documentURL: documentURL, nonce: nonce)

    return Response(
      status: .ok,
      headers: htmlSecurityHeaders(scriptNonce: nonce),
      body: ResponseBody(byteBuffer: ByteBuffer(string: withReload)))
  }

  private static func serveFile(at url: URL) -> Response {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return HTTPResponses.notFound(error.localizedDescription)
    }
    let mime = MIMETypes.mimeType(for: url)
    var headers: HTTPFields = [
      .contentType: mime,
      .cacheControl: "no-store",
      .xContentTypeOptions: "nosniff",
      .crossOriginResourcePolicy: "same-origin",
      .crossOriginOpenerPolicy: "same-origin"
    ]
    if mime.lowercased().hasPrefix("text/html") {
      headers[.contentSecurityPolicy] = strictAssetCSP
      headers[.xFrameOptions] = "DENY"
      headers[.referrerPolicy] = "no-referrer"
    }
    return Response(
      status: .ok,
      headers: headers,
      body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
  }

  // MARK: - /template/<id>/<file>

  private static func templateAssetResponse(
    request: Request
  ) async -> Response {
    guard case .templateAsset(let templateID, let file)
      = PreviewRoute(path: request.uri.path)
    else {
      return HTTPResponses.badRequest(
        String(
          localized: "Invalid template asset path",
          bundle: .galleyServerKit))
    }
    guard let template = await TemplateStore.shared
      .existingTemplate(forID: templateID)
    else {
      return HTTPResponses.notFound(
        String(
          localized: "Template not found: \(templateID)",
          bundle: .galleyServerKit))
    }
    guard let assetURL = template.resolveAsset(file: file) else {
      return HTTPResponses.notFound(
        String(
          localized:
            "No such asset in template '\(template.name)': \(file)",
          bundle: .galleyServerKit))
    }
    return serveFile(at: assetURL)
  }

  // MARK: - /events/<path> (SSE)

  private static func eventsResponse(
    request: Request,
    watcher: DocumentWatcher
  ) -> Response {
    guard
      let documentURL = decodeFilePath(
        from: request.uri.path, prefix: "/\(RouteNames.events)"),
      MarkdownFileTypes.extensions.contains(
        documentURL.pathExtension.lowercased())
    else {
      return HTTPResponses.badRequest(
        String(localized: "Invalid event path", bundle: .galleyServerKit))
    }

    let body = ResponseBody { writer in
      try await writer.write(ByteBuffer(string: ": connected\n\n"))
      let events = await watcher.subscribe(to: documentURL)
      for await _ in events {
        let payload = SSE.encode(event: "reload", data: "ok")
        try await writer.write(ByteBuffer(bytes: payload))
      }
      try await writer.finish(nil)
    }

    return Response(
      status: .ok,
      headers: [
        .contentType: "text/event-stream",
        .cacheControl: "no-cache",
        .connection: "keep-alive",
        .xAccelBuffering: "no"
      ],
      body: body)
  }

  // MARK: - Helpers

  /// Extracts a filesystem path from `requestPath` (e.g.
  /// "/preview/Users/foo.md") by stripping `prefix` ("/preview"). Returns
  /// the resolved file URL or nil if the extracted path is not absolute,
  /// escapes the filesystem root, has no extension, or refers to a
  /// dotfile (last path component starts with ".").
  ///
  /// Internal (not `private`) so unit tests can drive the path-decoding
  /// rules directly.
  static func decodeFilePath(
    from requestPath: String, prefix: String) -> URL?
  {
    guard requestPath.hasPrefix(prefix) else { return nil }
    let tail = String(requestPath.dropFirst(prefix.count))
    guard tail.hasPrefix("/") else { return nil }

    let decoded = tail.removingPercentEncoding ?? tail
    let url = URL(fileURLWithPath: decoded).safe
    guard url.path.hasPrefix("/") else { return nil }
    if url.lastPathComponent.hasPrefix(".") { return nil }
    return url
  }

  /// Internal (not `private`) so unit tests can verify the script is
  /// injected before `</body>` and that the nonce is wired through.
  static func injectReloadScript(
    into html: String, documentURL: URL, nonce: String) -> String
  {
    let encodedPath = documentURL.path.percentEncodedForPath
    let script = """
        <script nonce="\(nonce)">
        (function() {
          try {
            var src = new EventSource('/events\(encodedPath)');
            src.addEventListener('reload', function() { location.reload(); });
          } catch (e) { console.warn('livereload disabled:', e); }
        })();
        </script>
        """
    if let range = html.range(of: "</body>", options: .caseInsensitive) {
      return html.replacingCharacters(in: range, with: script + "\n</body>")
    }
    return html + "\n" + script
  }

  // MARK: - Security

  /// Rejects requests whose `Host` header is not a loopback alias on the
  /// expected port (DNS-rebinding defence) or that originate from another
  /// site (`Sec-Fetch-Site: cross-site` / `same-site`). Returns nil when
  /// the request is acceptable. `extra` widens the allowlist with
  /// additional hostnames (e.g., `"this-mac.local"`) when a paired
  /// Kosmos peer is connected.
  static func guardRequest(
    _ request: Request,
    hostURL: URL,
    extra: Set<String> = []
  ) -> Response? {
    let expectedPort = hostURL.port ?? defaultPort(forScheme: hostURL.scheme)
    // HTTP/1.1 carries Host in the request line authority; Hummingbird
    // surfaces it via `head.authority`. `HTTPField.Name.host` is marked
    // unavailable in swift-http-types in favour of this accessor.
    let hostHeader = request.head.authority ?? ""
    if !isHostAllowed(hostHeader, expectedPort: expectedPort, extra: extra) {
      return HTTPResponses.forbidden(
        String(localized: "Host header not allowed", bundle: .galleyServerKit))
    }
    if let site = request.headers[.secFetchSite]?.lowercased(),
       site != "same-origin", site != "none" {
      return HTTPResponses.forbidden(
        String(
          localized: "Cross-site request rejected",
          bundle: .galleyServerKit))
    }
    return nil
  }

  /// Internal (not `private`) so unit tests can drive the loopback host
  /// allowlist directly without constructing a full `Request`.
  static func isHostAllowed(
    _ value: String,
    expectedPort: Int,
    extra: Set<String> = []
  ) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          let url = URL(string: "http://\(trimmed)/")
    else { return false }
    var allowed: Set<String> = ["127.0.0.1", "localhost", "::1"]
    allowed.formUnion(extra.map { $0.lowercased() })
    guard let host = url.host?.lowercased(), allowed.contains(host)
    else { return false }
    return (url.port ?? 80) == expectedPort
  }

  private static func defaultPort(forScheme scheme: String?) -> Int {
    scheme?.lowercased() == "https" ? 443 : 80
  }

  /// Build the origin URL the rendered HTML should use as its
  /// `<base href>` from the request's own `Host` header and the
  /// scheme of the listener that's about to compose the response.
  /// Falls back to the listener's own URL (`hostURL`) if the request
  /// has no authority. Public visibility kept private — only routes
  /// use it.
  ///
  /// `hostURL.scheme` is the source-of-truth for the listener's
  /// scheme, since `Host` headers don't carry it.
  ///
  /// `X-Kosmos-Origin` overrides this when present (see
  /// `KosmosHTTPTunnel.TunnelHeaders.origin`). The AVP-side scheme
  /// handler sets it so the rendered HTML's `<base href>` points at
  /// the WebView's `kosmos://` origin instead of the loopback
  /// authority — without it, sub-resource fetches (CSS, JS, images)
  /// would resolve against `http://127.0.0.1:<port>/` and bypass
  /// the scheme handler. Not a security boundary: `<base href>`
  /// only steers the browser's outbound fetches, and the host-header
  /// guard already gated the caller. Use the header strictly for
  /// origin composition.
  static func templateOriginURL(
    for request: Request, fallback hostURL: URL
  ) -> URL {
    templateOriginURL(
      originHeader: request.headers[kosmosOriginHeader],
      authority: request.head.authority,
      fallback: hostURL)
  }

  private static let kosmosOriginHeader: HTTPField.Name = {
    guard let name = HTTPField.Name(TunnelHeaders.origin) else {
      preconditionFailure(
        "\(TunnelHeaders.origin) is a valid HTTP field name")
    }
    return name
  }()

  /// Pure decision: same as the `Request`-flavored overload but with
  /// the two inputs the `Request` exposes (Host authority + the
  /// `X-Kosmos-Origin` header), so tests can drive it without
  /// constructing a Hummingbird `Request`.
  static func templateOriginURL(
    originHeader: String?,
    authority: String?,
    fallback hostURL: URL
  ) -> URL {
    if let override = originHeader?.trimmingCharacters(in: .whitespaces),
       !override.isEmpty,
       let parsed = URL(string: override),
       parsed.scheme != nil, parsed.host != nil
    {
      return parsed
    }
    guard let authority, !authority.isEmpty else { return hostURL }
    let scheme = hostURL.scheme ?? "http"
    return URL(string: "\(scheme)://\(authority)") ?? hostURL
  }

  private static func generateNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      // Fallback: SystemRandomNumberGenerator is cryptographically secure
      // on Apple platforms, but SecRandomCopyBytes essentially never fails.
      var rng = SystemRandomNumberGenerator()
      for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255, using: &rng)
      }
    }
    return Data(bytes).base64EncodedString()
  }

  private static func htmlSecurityHeaders(
    scriptNonce nonce: String) -> HTTPFields
  {
    let csp = [
      "default-src 'none'",
      "script-src 'nonce-\(nonce)' 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:",
      "font-src 'self' data:",
      "media-src 'self' data: blob:",
      "connect-src 'self'",
      "frame-src 'self'",
      "form-action 'self'",
      "base-uri 'self'",
      "object-src 'none'"
    ].joined(separator: "; ")
    return [
      .contentType: "text/html; charset=utf-8",
      .cacheControl: "no-store",
      .contentSecurityPolicy: csp,
      .xContentTypeOptions: "nosniff",
      .xFrameOptions: "DENY",
      .referrerPolicy: "no-referrer",
      .crossOriginResourcePolicy: "same-origin",
      .crossOriginOpenerPolicy: "same-origin"
    ]
  }

  private static let strictAssetCSP: String = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    "media-src 'self' data: blob:",
    "connect-src 'self'",
    "frame-src 'self'",
    "form-action 'self'",
    "base-uri 'self'",
    "object-src 'none'"
  ].joined(separator: "; ")
}

/// Header names not covered by swift-http-types' built-in catalog.
/// `cacheControl`, `contentSecurityPolicy`, `crossOriginResourcePolicy`,
/// `xContentTypeOptions`, and `contentType` are provided by HTTPTypes.
/// Names are RFC-valid by construction, so the optional `init` is
/// guarded with `??` rather than force-unwrapped.
extension HTTPField.Name {
  private static func named(_ name: String) -> HTTPField.Name {
    guard let result = HTTPField.Name(name) else {
      preconditionFailure("Invalid HTTP header name: \(name)")
    }
    return result
  }

  static let crossOriginOpenerPolicy = named("Cross-Origin-Opener-Policy")
  static let referrerPolicy = named("Referrer-Policy")
  static let secFetchSite = named("Sec-Fetch-Site")
  static let xAccelBuffering = named("X-Accel-Buffering")
  static let xFrameOptions = named("X-Frame-Options")
}
