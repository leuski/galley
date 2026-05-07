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
  private lazy var navProxy = NavigationProxy()

  /// Lazy so that `preparePreviewOfFile(at:)` — which Quick Look calls
  /// before asking for our view — can touch the WebView and have it
  /// fully wired up. `loadView()` would otherwise run too late.
  private lazy var webView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    let handler = ClassicPreviewSchemeHandler { .bundledDefault }
    configuration.setURLSchemeHandler(
      handler, forURLScheme: PreviewScheme.name)
    let web = WKWebView(frame: .zero, configuration: configuration)
    web.translatesAutoresizingMaskIntoConstraints = false
    web.navigationDelegate = navProxy
    return web
  }()

  override var nibName: NSNib.Name? { nil }

  override func loadView() {
    self.view = webView
  }

  func preparePreviewOfFile(at url: URL) async throws {
    do {
      try await loadFromServer(Defaults.shared.host.appendingPreview(url))
    } catch {
      try await loadInProcess(file: url)
    }
  }

  // MARK: - Server path

  /// Loads the preview URL in the WebView and waits for navigation
  /// to finish. On any navigation failure (server down → connection
  /// refused, ATS denial, etc.) the underlying error propagates so
  /// the caller can fall back. The WebView load is itself the
  /// reachability probe — no separate ping needed, no race against a
  /// short timeout.
  @MainActor
  private func loadFromServer(_ url: URL) async throws {
    try await navProxy.run {
      self.webView.load(URLRequest(url: url))
    }
  }

  // MARK: - Fallback path (in-process render)

  @MainActor
  private func loadInProcess(file: URL) async throws {
    let composed = try await renderInProcess(file: file)
    try await navProxy.run {
      self.webView.loadHTMLString(composed.html, baseURL: composed.baseURL)
    }
  }

  /// Uses the shared `Template.composeHTML` recipe with
  /// `origin` = `PreviewScheme.originURL` so all asset URLs flow
  /// through `ClassicPreviewSchemeHandler` instead of an HTTP server.
  private func renderInProcess(file: URL) async throws -> ComposedPreview {
    let source = try String(contentsOf: file, encoding: .utf8)
    let body = try await SwiftMarkdownRenderer().render(source, baseURL: file)
    let template: Template = .bundledDefault
    return try template.composeHTML(
      documentContent: body,
      documentURL: file,
      origin: PreviewScheme.originURL)
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
