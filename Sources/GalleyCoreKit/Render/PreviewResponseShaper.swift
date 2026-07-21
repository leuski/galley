import Foundation
import KosmosAppKit
import Security

/// Maps a transport-neutral ``PreviewResponse`` onto a fully-shaped
/// ``ShapedResponse``. Stateless and `Sendable`; construct freely.
public struct PreviewResponseShaper: Sendable {
  public init() {}

  public func shape(_ preview: PreviewResponse) -> ShapedResponse {
    switch preview {
    case .html(let html, let documentURL):
      shapedHTML(html, documentURL: documentURL)
    case .bytes(let resolved):
      ShapedResponse(
        status: 200,
        headers: .security(
          contentType: resolved.mime, cacheControl: resolved.cache),
        body: .bytes(resolved.data))
    case .events(let documentURL):
      ShapedResponse(
        status: 200,
        headers: .eventStream,
        body: .eventStream(documentURL: documentURL))
    case .plainText(let text):
      plainText(status: 200, text)
    case .badRequest(let message):
      plainText(status: 400, message)
    case .notFound(let message):
      plainText(status: 404, message)
    case .failure(let failure):
      errorPage(failure)
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
      status: 200, headers: .htmlSecurity(scriptNonce: nonce), body: withReload)
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

  // MARK: - Plain text

  private func plainText(status: Int, _ message: String) -> ShapedResponse {
    ShapedResponse(status: status, headers: .utf8Text, body: message + "\n")
  }

  // MARK: - Localized error page

  private func errorPage(_ failure: PreviewFailure) -> ShapedResponse {
    let title: String
    let detail: String
    let source: String
    switch failure {
    case .noProcessor:
      title = localized("No markdown processor configured")
      detail = localized(
        """
        Install a supported processor (e.g. multimarkdown via Homebrew) \
        and pick it in Settings.
        """)
      source = ""
    case .render(let renderDetail, let renderSource):
      title = localized("Render error")
      detail = renderDetail
      source = renderSource
    case .template(let name, let templateDetail, let templateSource):
      title = localized("Template error")
      detail = localized(
        "Cannot load template '\(name)': \(templateDetail)")
      source = templateSource
    }
    let html = Self.errorPageTemplate.substituting(substitutions: [
      "#TITLE#": title.htmlEscaped,
      "#DETAIL#": detail.htmlEscaped,
      "#SOURCE#": source.htmlEscaped
    ])
    return ShapedResponse(status: 500, headers: .utf8Html, body: html)
  }

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

  private static let errorPageTemplate: String =
  Bundle.galleyCoreKit.requiredString(
    forResource: "ErrorPage", withExtension: "html")
}
