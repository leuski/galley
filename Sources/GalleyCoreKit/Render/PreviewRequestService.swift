import Foundation
import KosmosAppKit

/// A transport-neutral preview response. Produced by
/// ``PreviewRequestService`` and mapped onto whatever the caller speaks:
/// FlyingFox `Response` for the HTTP routes, ``TunnelResponseEvent`` for
/// the Kosmos tunnel backend. Errors are *structured* (not pre-rendered
/// HTML) so each transport localizes its own error page.
public enum PreviewResponse: Sendable {
  /// Rendered document HTML. Always `no-store`.
  case html(String, documentURL: URL)
  /// Static bytes (a document-relative sibling or a template asset),
  /// carrying their own MIME + cache verdict.
  case bytes(ResolvedBytes)
  /// A live-reload event stream for `documentURL`. The caller wires the
  /// `DocumentWatcher` subscription + SSE encoding for its transport.
  case events(documentURL: URL)
  /// Plain-text OK (the `/` index).
  case plainText(String)
  case badRequest(String)
  case notFound(String)
  /// A structured failure the caller renders as a localized error page.
  case failure(PreviewFailure)
}

/// A structured preview failure. The caller turns it into a localized
/// error page (the strings live with each transport, not here).
public enum PreviewFailure: Sendable {
  /// No Markdown processor is configured/available.
  case noProcessor
  /// The renderer threw. `source` is the raw Markdown, for the page.
  case render(detail: String, source: String)
  /// The template failed to load/compose. `source` is the rendered body.
  case template(name: String, detail: String, source: String)
}

/// Single source of truth for "turn a preview request path into a
/// response," shared by the live HTTP routes and the in-process Kosmos
/// tunnel backend. Owns the `/preview`, `/template`, `/events`, and `/`
/// behaviors; knows nothing about the transport carrying the result.
///
/// Renderer + template are read per request via providers, so a menu
/// pick takes effect on the next request with no restart.
public struct PreviewRequestService: Sendable {
  /// Extensions served as static assets (vs. rendered as Markdown).
  public static let assetExtensions: Set<String> = [
    "txt", "html", "htm",
    "css", "js", "json", "map",
    "svg", "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff", "tif",
    "woff", "woff2", "ttf", "otf",
    "mp4", "webm", "mp3", "wav", "ogg",
    "pdf"
  ]

  private let selectedTemplate: @Sendable () async -> Template
  private let renderer: @Sendable () async -> (any MarkdownRenderer)?

  public init(
    selectedTemplate: @escaping @Sendable () async -> Template,
    renderer: @escaping @Sendable () async -> (any MarkdownRenderer)?
  ) {
    self.selectedTemplate = selectedTemplate
    self.renderer = renderer
  }

  /// Resolve a request `path` (e.g. `/preview/Users/.../doc.md`) into a
  /// neutral response. `origin` is the URL whose authority the rendered
  /// HTML's `<base href>` should use — the requester's own host, so
  /// sub-resource fetches come back to the same transport.
  public func respond(path: String, origin: URL) async -> PreviewResponse {
    if path.hasPrefix("/\(RouteNames.preview)") {
      return await previewOrAsset(path: path, origin: origin)
    }
    if path.hasPrefix("/\(RouteNames.template)/") {
      return await templateAsset(path: path)
    }
    if path.hasPrefix("/\(RouteNames.events)") {
      return events(path: path)
    }
    if path == "/" {
      return .plainText("Galley Server is running.")
    }
    return .notFound("Not found: \(path)")
  }

  // MARK: - /preview/<path>

  private func previewOrAsset(
    path: String, origin: URL
  ) async -> PreviewResponse {
    guard let documentURL = Self.decodeAbsolutePath(
      path, prefix: "/\(RouteNames.preview)")
    else {
      return .badRequest("Invalid path")
    }
    let ext = documentURL.pathExtension.lowercased()
    if MarkdownFileTypes.extensions.contains(ext) {
      guard let renderer = await renderer() else {
        return .failure(.noProcessor)
      }
      return await renderPreview(
        documentURL: documentURL,
        origin: origin,
        template: await selectedTemplate(),
        renderer: renderer)
    }
    if Self.assetExtensions.contains(ext) {
      return serveFile(at: documentURL, cache: .noStore)
    }
    return .notFound("Unsupported extension: .\(ext)")
  }

  private func renderPreview(
    documentURL: URL,
    origin: URL,
    template: Template,
    renderer: any MarkdownRenderer
  ) async -> PreviewResponse {
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
      return .failure(.render(
        detail: error.localizedDescription, source: source))
    }

    do {
      let composed = try template.composeHTML(
        documentContent: renderedBody,
        documentURL: documentURL,
        origin: origin)
      return .html(composed.html, documentURL: documentURL)
    } catch {
      return .failure(.template(
        name: String(localized: template.name),
        detail: error.localizedDescription,
        source: renderedBody))
    }
  }

  /// Read a file's bytes. `.noStore` for live-edited document siblings;
  /// the template-asset route passes a bounded `.maxAge`.
  private func serveFile(at url: URL, cache: CachePolicy) -> PreviewResponse {
    do {
      return .bytes(ResolvedBytes(
        data: try Data(contentsOf: url),
        mime: MIMETypes.mimeType(for: url),
        cache: cache))
    } catch {
      return .notFound(error.localizedDescription)
    }
  }

  // MARK: - /template/<id>/<file>

  private func templateAsset(path: String) async -> PreviewResponse {
    let route = PreviewRoute(path: path)
    guard case .templateAsset(let templateID, let file) = route else {
      return .badRequest("Invalid template asset path")
    }
    guard let template = await TemplateStore.shared
      .existingTemplate(forID: templateID)
    else {
      return .notFound("Template not found: \(templateID)")
    }
    guard let assetURL = template.resolveAsset(file: file) else {
      return .notFound(
        "No such asset in template '\(template.name)': \(file)")
    }
    return serveFile(
      at: assetURL,
      cache: PreviewRoute.templateAsset(id: templateID, file: file).cachePolicy)
  }

  // MARK: - /events/<path> (SSE)

  private func events(path: String) -> PreviewResponse {
    guard
      let documentURL = Self.decodeAbsolutePath(
        path, prefix: "/\(RouteNames.events)"),
      MarkdownFileTypes.extensions.contains(
        documentURL.pathExtension.lowercased())
    else {
      return .badRequest("Invalid event path")
    }
    return .events(documentURL: documentURL)
  }

  // MARK: - Helpers

  /// Decode the absolute filesystem path tail of a route (the same shape
  /// `URL.appendingPreview(_:)` produces and `PreviewRoute` parses for
  /// `/preview`). Percent-decoded, leading slash ensured.
  static func decodeAbsolutePath(_ path: String, prefix: String) -> URL? {
    guard path.hasPrefix(prefix) else { return nil }
    var tail = String(path.dropFirst(prefix.count))
    if !tail.hasPrefix("/") { tail = "/" + tail }
    let decoded = tail.removingPercentEncoding ?? tail
    return URL(fileURLWithPath: decoded)
  }
}
