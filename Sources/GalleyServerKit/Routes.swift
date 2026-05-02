import Foundation
import FlyingFox
import Security
import GalleyCoreKit

enum Routes {
  static let assetExtensions: Set<String> = [
    "txt", "html", "htm",
    "css", "js", "json", "map",
    "svg", "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "tif",
    "woff", "woff2", "ttf", "otf",
    "mp4", "webm", "mp3", "wav", "ogg",
    "pdf"
  ]

  static func register(
    on server: HTTPServer,
    hostURL: URL,
    templateStore: TemplateStore,
    selectedTemplateProvider: @Sendable @escaping () async -> Template,
    rendererProvider: @Sendable @escaping () async -> (any MarkdownRenderer)?,
    watcher: DocumentWatcher
  ) async {
    let storeRef = TemplateStoreRef(templateStore)

    await server.appendRoute(
      .init(method: .GET, path: "/\(RouteNames.preview)/*")) { request in
        if let denied = guardRequest(request, hostURL: hostURL) {
          return denied
        }
        return await previewOrAssetResponse(
          request: request,
          hostURL: hostURL,
          selectedTemplate: await selectedTemplateProvider(),
          renderer: await rendererProvider())
      }

    await server.appendRoute(
      .init(method: .GET, path: "/\(RouteNames.template)/*")) { request in
        if let denied = guardRequest(request, hostURL: hostURL) {
          return denied
        }
        return await templateAssetResponse(
          request: request, templateStore: storeRef)
      }

    await server.appendRoute(
      .init(method: .GET, path: "/\(RouteNames.events)/*")) { request in
        if let denied = guardRequest(request, hostURL: hostURL) {
          return denied
        }
        return await eventsResponse(request: request, watcher: watcher)
      }

    await server.appendRoute("GET /") { request in
      if let denied = guardRequest(request, hostURL: hostURL) {
        return denied
      }
      return HTTPResponse(
        statusCode: .ok,
        headers: [.contentType: "text/plain; charset=utf-8"],
        body: Data("MarkdownPreviewer is running.\n".utf8))
    }
  }

  // MARK: - /preview/<path>

  private static func previewOrAssetResponse(
    request: HTTPRequest,
    hostURL: URL,
    selectedTemplate: Template,
    renderer: (any MarkdownRenderer)?
  ) async -> HTTPResponse {
    guard let documentURL = decodeFilePath(
      from: request.path, prefix: "/\(RouteNames.preview)")
    else {
      return HTTPResponses.badRequest("Invalid path")
    }

    let ext = documentURL.pathExtension.lowercased()
    if MarkdownFileTypes.extensions.contains(ext) {
      guard let renderer else {
        return HTTPResponses.errorPage(
          title: "No markdown processor configured",
          detail: """
            Install a supported processor (e.g. multimarkdown via Homebrew) \
            and pick it in Settings.
            """,
          source: "")
      }
      return await renderPreview(
        documentURL: documentURL,
        request: request,
        hostURL: hostURL,
        template: selectedTemplate,
        renderer: renderer)
    }
    if assetExtensions.contains(ext) {
      return serveFile(at: documentURL)
    }
    return HTTPResponses.notFound("Unsupported extension: .\(ext)")
  }

  private static func renderPreview(
    documentURL: URL,
    request: HTTPRequest,
    hostURL: URL,
    template: Template,
    renderer: any MarkdownRenderer
  ) async -> HTTPResponse {
    guard FileManager.default.isReadableFile(atPath: documentURL.path) else {
      return HTTPResponses.notFound("Cannot read \(documentURL.path)")
    }

    let source: String
    do {
      source = try String(contentsOf: documentURL, encoding: .utf8)
    } catch {
      return HTTPResponses.notFound(
        "Cannot read \(documentURL.path): \(error.localizedDescription)")
    }

    let renderedBody: String
    do {
      renderedBody = try await renderer.render(source, baseURL: documentURL)
    } catch {
      return HTTPResponses.errorPage(
        title: "Render error",
        detail: error.localizedDescription,
        source: source)
    }

    let templateHTML: String
    do {
      templateHTML = try template.loadHTML()
    } catch {
      return HTTPResponses.errorPage(
        title: "Template error",
        detail: """
          Cannot load template '\(template.name)': \
          \(error.localizedDescription)
          """,
        source: renderedBody)
    }

    let origin = hostURL
    let processedTemplate = template.rewriteAssets(
      in: templateHTML, origin: origin)
    let context = PlaceholderContext(
      documentContent: renderedBody,
      documentURL: documentURL,
      origin: origin)
    let substituted = context.substitute(into: processedTemplate)
    let nonce = generateNonce()
    let withReload = injectReloadScript(
      into: substituted, documentURL: documentURL, nonce: nonce)

    return HTTPResponse(
      statusCode: .ok,
      headers: htmlSecurityHeaders(scriptNonce: nonce),
      body: Data(withReload.utf8))
  }

  private static func serveFile(at url: URL) -> HTTPResponse {
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      return HTTPResponses.notFound("File not found: \(url.path)")
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return HTTPResponses.notFound(error.localizedDescription)
    }
    let mime = MIMETypes.mimeType(for: url)
    var headers: HTTPHeaders = [
      .contentType: mime,
      HTTPHeader("Cache-Control"): "no-store",
      HTTPHeader("X-Content-Type-Options"): "nosniff",
      HTTPHeader("Cross-Origin-Resource-Policy"): "same-origin",
      HTTPHeader("Cross-Origin-Opener-Policy"): "same-origin"
    ]
    if mime.lowercased().hasPrefix("text/html") {
      headers[HTTPHeader("Content-Security-Policy")] = strictAssetCSP
      headers[HTTPHeader("X-Frame-Options")] = "DENY"
      headers[HTTPHeader("Referrer-Policy")] = "no-referrer"
    }
    return HTTPResponse(statusCode: .ok, headers: headers, body: data)
  }

  // MARK: - /template/<id>/<file>

  private static func templateAssetResponse(
    request: HTTPRequest,
    templateStore: TemplateStoreRef
  ) async -> HTTPResponse {
    guard case .templateAsset(let templateID, let file)
      = PreviewRoute(path: request.path)
    else {
      return HTTPResponses.badRequest("Invalid template asset path")
    }
    guard let template = await templateStore.template(id: templateID) else {
      return HTTPResponses.notFound("Template not found: \(templateID)")
    }
    guard let assetURL = template.resolveAsset(file: file) else {
      return HTTPResponses.notFound(
        "No such asset in template '\(template.name)': \(file)")
    }
    return serveFile(at: assetURL)
  }

  // MARK: - /events/<path> (SSE)

  private static func eventsResponse(
    request: HTTPRequest,
    watcher: DocumentWatcher
  ) async -> HTTPResponse {
    guard
      let documentURL = decodeFilePath(
        from: request.path, prefix: "/\(RouteNames.events)"),
      MarkdownFileTypes.extensions.contains(
        documentURL.pathExtension.lowercased())
    else {
      return HTTPResponses.badRequest("Invalid event path")
    }

    let bodyStream = AsyncStream<Data> { continuation in
      let task = Task {
        continuation.yield(Data(": connected\n\n".utf8))
        let events = await watcher.subscribe(to: documentURL)
        for await _ in events {
          continuation.yield(SSE.encode(event: "reload", data: "ok"))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }

    let body = HTTPBodySequence(from: SSEByteSequence(upstream: bodyStream))

    return HTTPResponse(
      statusCode: .ok,
      headers: [
        .contentType: "text/event-stream",
        HTTPHeader("Cache-Control"): "no-cache",
        HTTPHeader("Connection"): "keep-alive",
        HTTPHeader("X-Accel-Buffering"): "no"
      ],
      body: body)
  }

  // MARK: - Helpers

  /// Extracts a filesystem path from `request.path` (e.g.
  /// "/preview/Users/foo.md") by stripping `prefix` ("/preview"). Returns
  /// the resolved file URL or nil if the extracted path is not absolute,
  /// escapes the filesystem root, has no extension, or refers to a
  /// dotfile (last path component starts with ".").
  private static func decodeFilePath(
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

  private static func injectReloadScript(
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
  /// the request is acceptable.
  private static func guardRequest(
    _ request: HTTPRequest, hostURL: URL) -> HTTPResponse?
  {
    let expectedPort = hostURL.port ?? 80
    let hostHeader = request.headers[.host] ?? ""
    if !isHostAllowed(hostHeader, expectedPort: expectedPort) {
      return HTTPResponses.forbidden("Host header not allowed")
    }
    if let site = request.headers[HTTPHeader("Sec-Fetch-Site")]?.lowercased(),
       site != "same-origin", site != "none" {
      return HTTPResponses.forbidden("Cross-site request rejected")
    }
    return nil
  }

  private static func isHostAllowed(
    _ value: String, expectedPort: Int) -> Bool
  {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          let url = URL(string: "http://\(trimmed)/")
    else { return false }
    let allowed: Set<String> = ["127.0.0.1", "localhost", "::1"]
    guard let host = url.host?.lowercased(), allowed.contains(host)
    else { return false }
    return (url.port ?? 80) == expectedPort
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
    scriptNonce nonce: String) -> HTTPHeaders
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
      HTTPHeader("Cache-Control"): "no-store",
      HTTPHeader("Content-Security-Policy"): csp,
      HTTPHeader("X-Content-Type-Options"): "nosniff",
      HTTPHeader("X-Frame-Options"): "DENY",
      HTTPHeader("Referrer-Policy"): "no-referrer",
      HTTPHeader("Cross-Origin-Resource-Policy"): "same-origin",
      HTTPHeader("Cross-Origin-Opener-Policy"): "same-origin"
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

private struct TemplateStoreRef: Sendable {
  private let store: TemplateStore

  init(_ store: TemplateStore) {
    self.store = store
  }

  func template(id: String) async -> Template? {
    await MainActor.run { store.existingTemplate(forID: id) }
  }
}

private extension HTTPRequest {
  func query(_ name: String) -> String? {
    for item in query where item.name == name {
      return item.value
    }
    return nil
  }
}
