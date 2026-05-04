import AppKit
import Quartz
import WebKit
import GalleyCoreKit

/// Quick Look preview for Markdown files.
///
/// Tries the running Markdown Preview Server first so the user's
/// chosen processor and template are honored. Falls back to an
/// in-process render with the built-in Swift renderer and bundled
/// template when the server is unreachable (typical when the menu-bar
/// app isn't running).
final class PreviewViewController: NSViewController, QLPreviewingController {
  private var webView: WKWebView?
  private var navProxy: NavigationProxy?

  override var nibName: NSNib.Name? { nil }

  override func loadView() {
    let config = WKWebViewConfiguration()
    let web = WKWebView(frame: .zero, configuration: config)
    web.translatesAutoresizingMaskIntoConstraints = false
    let proxy = NavigationProxy()
    web.navigationDelegate = proxy
    self.webView = web
    self.navProxy = proxy
    self.view = web
  }

  func preparePreviewOfFile(at url: URL) async throws {
    let port = readSharedPort()
    if let serverURL = makeServerURL(file: url, port: port),
       await isServerReachable(serverURL) {
      try await loadFromServer(serverURL)
    } else {
      try await loadInProcess(file: url)
    }
  }

  // MARK: - Shared defaults

  private func readSharedPort() -> UInt16 {
    let defaults = UserDefaults(suiteName: GalleyConstants.suiteName)
    if let raw = defaults?.object(forKey: "port") as? Int, raw > 0 {
      return UInt16(clamping: raw)
    }
    return GalleyConstants.defaultPort
  }

  // MARK: - Server path

  private func makeServerURL(file: URL, port: UInt16) -> URL? {
    var components = URLComponents()
    components.scheme = "http"
    components.host = GalleyConstants.defaultHost
    components.port = Int(port)
    components.path = "/\(RouteNames.preview)"
      + file.standardizedFileURL.path
    return components.url
  }

  private func isServerReachable(_ url: URL) async -> Bool {
    var req = URLRequest(url: url)
    req.httpMethod = "HEAD"
    req.timeoutInterval = 0.5
    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200..<400).contains(http.statusCode)
    } catch {
      return false
    }
  }

  @MainActor
  private func loadFromServer(_ url: URL) async throws {
    try await navProxy?.run { [webView] in
      webView?.load(URLRequest(url: url))
    }
  }

  // MARK: - Fallback path (in-process render)

  @MainActor
  private func loadInProcess(file: URL) async throws {
    let html = try await renderInProcess(file: file)
    let parent = file.deletingLastPathComponent()
    try await navProxy?.run { [webView] in
      webView?.loadHTMLString(html, baseURL: parent)
    }
  }

  private func renderInProcess(file: URL) async throws -> String {
    let source = try String(contentsOf: file, encoding: .utf8)
    let body = try await SwiftMarkdownRenderer().render(
      source, baseURL: file)
    let template = try BuiltInTemplate.shared.loadHTML()
    return applyFallbackPlaceholders(
      template: template, file: file, body: body)
  }

  /// Minimal `#TOKEN#` substitution for the QL fallback render.
  /// `PlaceholderContext` assumes an HTTP server origin and rewrites
  /// `#BASE#` through `/preview/...`; here `#BASE#` is the file's
  /// parent directory as a `file://` URL so relative images resolve
  /// directly.
  private func applyFallbackPlaceholders(
    template: String, file: URL, body: String) -> String
  {
    let parent = file.deletingLastPathComponent()
    let baseHref = parent.absoluteString.hasSuffix("/")
      ? parent.absoluteString
      : parent.absoluteString + "/"
    let baseName = file.deletingPathExtension().lastPathComponent
    let replacements: KeyValuePairs<String, String> = [
      "#DOCUMENT_CONTENT#": body,
      "#TITLE#": htmlAttributeEscape(baseName),
      "#BASE#": htmlAttributeEscape(baseHref),
      "#FILE#": htmlAttributeEscape(file.lastPathComponent),
      "#BASENAME#": htmlAttributeEscape(baseName),
      "#FILE_EXTENSION#": htmlAttributeEscape(file.pathExtension),
      "#DATE#": "",
      "#TIME#": ""
    ]
    var output = template
    for (token, value) in replacements {
      output = output.replacingOccurrences(of: token, with: value)
    }
    return output
  }

  private func htmlAttributeEscape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

// MARK: - Navigation completion bridge

/// Bridges `WKNavigationDelegate` callbacks to async/await so
/// `preparePreviewOfFile(at:)` can return only after the WebView has
/// finished rendering. Quick Look keeps the loading spinner up until
/// the function returns.
private final class NavigationProxy: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, Error>?

  @MainActor
  func run(_ trigger: () -> Void) async throws {
    try await withCheckedThrowingContinuation { cont in
      self.continuation = cont
      trigger()
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard let cont = continuation else { return }
    continuation = nil
    switch result {
    case .success: cont.resume()
    case .failure(let error): cont.resume(throwing: error)
    }
  }

  func webView(
    _ webView: WKWebView, didFinish navigation: WKNavigation!)
  {
    finish(.success(()))
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error)
  {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error)
  {
    finish(.failure(error))
  }
}
