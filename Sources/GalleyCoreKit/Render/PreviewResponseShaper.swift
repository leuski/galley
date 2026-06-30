import Foundation
import KosmosAppKit
import Security

/// A fully-shaped, transport-neutral HTTP-style response: the status,
/// headers, and body a caller emits regardless of whether the carrier is
/// the FlyingFox HTTP listener (`GalleyServerKit`) or the Kosmos tunnel
/// (``InProcessTunnelBackend``). This is the single source of truth for
/// response *shaping* — live-reload `<script>` injection, the nonce CSP +
/// security headers, the SSE headers + frame bytes, and the localized
/// error page — so both carriers emit byte-identical output without
/// either of them depending on a concrete HTTP-server library.
public struct ShapedResponse: Sendable {
  /// Numeric HTTP status (e.g. 200, 404, 500).
  public let status: Int
  /// Headers keyed by canonical name (`Content-Type`, `Cache-Control`…).
  public let headers: [String: String]
  public let body: Body

  public enum Body: Sendable {
    /// A complete, bounded payload.
    case bytes(Data)
    /// A live-reload event stream for `documentURL`. The carrier wires
    /// the `DocumentWatcher` subscription itself and emits ``PreviewSSE``
    /// frames (``PreviewSSE/connectPrelude`` once, then
    /// ``PreviewSSE/reloadFrame`` on each change).
    case eventStream(documentURL: URL)
  }

  public init(status: Int, headers: [String: String], body: Body) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

/// The exact server-sent-event frame bytes for the live-reload stream,
/// owned here so the HTTP and tunnel carriers frame identically.
public enum PreviewSSE {
  /// Sent once when the stream opens.
  public static let connectPrelude = Data(": connected\n\n".utf8)
  /// Sent on each observed document change; the injected page script
  /// listens for the `reload` event and reloads.
  public static let reloadFrame = Data("event: reload\ndata: ok\n\n".utf8)
}

/// Maps a transport-neutral ``PreviewResponse`` onto a fully-shaped
/// ``ShapedResponse``. Stateless and `Sendable`; construct freely.
public struct PreviewResponseShaper: Sendable {
  public init() {}

  public func shape(_ preview: PreviewResponse) -> ShapedResponse {
    switch preview {
    case .html(let html, let documentURL):
      return shapedHTML(html, documentURL: documentURL)
    case .bytes(let resolved):
      return shapedAsset(resolved)
    case .events(let documentURL):
      return ShapedResponse(
        status: 200,
        headers: Self.eventStreamHeaders,
        body: .eventStream(documentURL: documentURL))
    case .plainText(let text):
      return plainText(status: 200, text)
    case .badRequest(let message):
      return plainText(status: 400, message)
    case .notFound(let message):
      return plainText(status: 404, message)
    case .failure(let failure):
      return errorPage(failure)
    }
  }

  // MARK: - Rendered document HTML

  private func shapedHTML(
    _ html: String, documentURL: URL
  ) -> ShapedResponse {
    let nonce = Self.generateNonce()
    let withReload = Self.injectReloadScript(
      into: html, documentURL: documentURL, nonce: nonce)
    return ShapedResponse(
      status: 200,
      headers: Self.htmlSecurityHeaders(scriptNonce: nonce),
      body: .bytes(Data(withReload.utf8)))
  }

  /// Internal (not `private`) so unit tests can verify the script is
  /// injected before `</body>` and that the nonce is wired through.
  static func injectReloadScript(
    into html: String, documentURL: URL, nonce: String
  ) -> String {
    let encodedPath = documentURL.path.percentEncodedForPath
    let events = PreviewRoute.Name.events.rawValue
    let script = """
        <script nonce="\(nonce)">
        (function() {
          try {
            var src = new EventSource('/\(events)\(encodedPath)');
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

  // MARK: - Static assets

  private func shapedAsset(_ resolved: ResolvedBytes) -> ShapedResponse {
    var headers: [String: String] = [
      "Content-Type": resolved.mime,
      "Cache-Control": resolved.cache.cacheControl,
      "X-Content-Type-Options": "nosniff",
      "Cross-Origin-Resource-Policy": "same-origin",
      "Cross-Origin-Opener-Policy": "same-origin"
    ]
    if resolved.mime.lowercased().hasPrefix("text/html") {
      headers["Content-Security-Policy"] = Self.strictAssetCSP
      headers["X-Frame-Options"] = "DENY"
      headers["Referrer-Policy"] = "no-referrer"
    }
    return ShapedResponse(
      status: 200, headers: headers, body: .bytes(resolved.data))
  }

  // MARK: - Plain text

  private func plainText(status: Int, _ message: String) -> ShapedResponse {
    ShapedResponse(
      status: status,
      headers: ["Content-Type": "text/plain; charset=utf-8"],
      body: .bytes(Data((message + "\n").utf8)))
  }

  // MARK: - Localized error page

  private func errorPage(_ failure: PreviewFailure) -> ShapedResponse {
    let title: String
    let detail: String
    let source: String
    switch failure {
    case .noProcessor:
      title = Self.localized("No markdown processor configured")
      detail = Self.localized(
        """
        Install a supported processor (e.g. multimarkdown via Homebrew) \
        and pick it in Settings.
        """)
      source = ""
    case .render(let renderDetail, let renderSource):
      title = Self.localized("Render error")
      detail = renderDetail
      source = renderSource
    case .template(let name, let templateDetail, let templateSource):
      title = Self.localized("Template error")
      detail = String(
        format: Self.localized("Cannot load template '%@': %@"),
        name, templateDetail)
      source = templateSource
    }
    let html = Self.errorPageTemplate.substituting(substitutions: [
      "#TITLE#": title.htmlEscaped,
      "#DETAIL#": detail.htmlEscaped,
      "#SOURCE#": source.htmlEscaped
    ])
    return ShapedResponse(
      status: 500,
      headers: ["Content-Type": "text/html; charset=utf-8"],
      body: .bytes(Data(html.utf8)))
  }

  // MARK: - Headers

  static let eventStreamHeaders: [String: String] = [
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no"
  ]

  private static func htmlSecurityHeaders(
    scriptNonce nonce: String
  ) -> [String: String] {
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
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": csp,
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
      "Cross-Origin-Resource-Policy": "same-origin",
      "Cross-Origin-Opener-Policy": "same-origin"
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

  // MARK: - Helpers

  private static func generateNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      // SecRandomCopyBytes essentially never fails; the system RNG is
      // cryptographically secure on Apple platforms as a fallback.
      var rng = SystemRandomNumberGenerator()
      for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255, using: &rng)
      }
    }
    return Data(bytes).base64EncodedString()
  }

  private static func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .galleyCoreKit)
  }

  private static let errorPageTemplate: String =
    Bundle.galleyCoreKit.requiredString(
      forResource: "ErrorPage", withExtension: "html")
}
