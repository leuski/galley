import AppKit
import Quartz
import WebKit
import GalleyCoreKit

@ObservableDefaults(
  suiteName: "net.leuski.galley",
  limitToInstance: false)
final class Defaults: GalleyNetworkDefaults {
  @DefaultsKey var port: UInt16 = GalleyConstants.defaultPort

  @MainActor static let shared = Defaults()
}

/// Quick Look preview for Markdown files.
///
/// Tries the running Markdown Preview Server first so the user's
/// chosen processor and template are honored. Falls back to an
/// in-process render with the built-in Swift renderer and bundled
/// template when the server is unreachable (typical when the menu-bar
/// app isn't running). The fallback uses the same recipe as the
/// server (`template.rewriteAssets` + `PlaceholderContext.substitute`)
/// against `PreviewScheme.originURL`, with `ClassicPreviewSchemeHandler`
/// resolving asset URLs back to the filesystem.
final class PreviewViewController: NSViewController, QLPreviewingController {
  private var webView: WKWebView?
  private var navProxy: NavigationProxy?

  override var nibName: NSNib.Name? { nil }

  override func loadView() {
    let configuration = WKWebViewConfiguration()
    let handler = ClassicPreviewSchemeHandler {
      .builtIn(.shared)
    }
    configuration.setURLSchemeHandler(
      handler, forURLScheme: PreviewScheme.name)

    let web = WKWebView(frame: .zero, configuration: configuration)
    web.translatesAutoresizingMaskIntoConstraints = false
    let proxy = NavigationProxy()
    web.navigationDelegate = proxy
    self.webView = web
    self.navProxy = proxy
    self.view = web
  }

  func preparePreviewOfFile(at url: URL) async throws {
    let serverURL = Defaults.shared.host.appendingPreview(url)
    if await isServerReachable(serverURL) {
      try await loadFromServer(serverURL)
    } else {
      try await loadInProcess(file: url)
    }
  }

  // MARK: - Server path

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
    try await navProxy?.run { [webView] in
      webView?.loadHTMLString(html, baseURL: PreviewScheme.originURL)
    }
  }

  /// Same recipe the server uses in
  /// `GalleyServerKit.Routes.renderPreview`, with `origin` =
  /// `PreviewScheme.originURL` so all asset URLs flow through
  /// `ClassicPreviewSchemeHandler` instead of an HTTP server.
  private func renderInProcess(file: URL) async throws -> String {
    let source = try String(contentsOf: file, encoding: .utf8)
    let body = try await SwiftMarkdownRenderer().render(
      source, baseURL: file)
    let template: Template = .builtIn(.shared)
    let templateHTML = try template.loadHTML()
    let origin = PreviewScheme.originURL
    let processed = template.rewriteAssets(in: templateHTML, origin: origin)
    let context = PlaceholderContext(
      documentContent: body,
      documentURL: file,
      origin: origin)
    return context.substitute(into: processed)
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
