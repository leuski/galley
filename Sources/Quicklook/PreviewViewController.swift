import AppKit
import Quartz
import WebKit
import GalleyCoreKit
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "QuicklookPreview")

/// Quick Look preview for Markdown files.
///
/// Tries the running Markdown Preview Server first so the user's
/// chosen processor and template are honored. Falls back to an
/// in-process render with the built-in Swift renderer when the server
/// is unreachable (typical when the menu-bar app isn't running). The
/// fallback still honors the user's **selected template** (read from
/// the shared defaults via `Defaults.shared.template`), resolving it
/// through `TemplateStore` and dropping to the bundled default only
/// when the stored template can't be found. It uses the same recipe as
/// the server (`template.rewriteAssets` + `PlaceholderContext.substitute`)
/// against `PreviewScheme.originURL`, with `ClassicPreviewSchemeHandler`
/// resolving asset URLs back to the filesystem.
final class PreviewViewController: NSViewController, QLPreviewingController {
  private lazy var navProxy = NavigationProxy()

  /// Lazy so that `preparePreviewOfFile(at:)` — which Quick Look calls
  /// before asking for our view — can touch the WebView and have it
  /// fully wired up. `loadView()` would otherwise run too late.
  private lazy var webView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    let handler = ClassicPreviewSchemeHandler {
      PreviewViewController.resolvedTemplate()
    }
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
    if let endpoint = Defaults.shared.serverEndpointURL {
      do {
        try await loadFromServer(endpoint.appendingPreview(url))
        return
      } catch {
        // Fall through to in-process render.
        log.debug("""
          QuickLook server path failed; falling back in-process: \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    try await loadInProcess(file: url)
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
    return try Self.resolvedTemplate().composeHTML(
      documentContent: body,
      documentURL: file,
      origin: PreviewScheme.originURL)
  }

  /// The user's selected template, read from the shared defaults and
  /// resolved through `TemplateStore`. Falls back to the bundled default
  /// when nothing is stored or the stored template can't be found (e.g.
  /// a user template the sandbox can't reach). Shared by the render
  /// recipe and the scheme handler so `/template/<id>/…` asset URLs
  /// resolve against the same template.
  @MainActor
  private static func resolvedTemplate() -> Template {
    TemplateStore.shared.existingTemplate(forID: Defaults.shared.template?.id)
      ?? .bundledDefault
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

  // Quicklook hits `http://127.0.0.1:<port>/…` via
  // `Defaults.shared.serverEndpointURL`. Loopback HTTP only; no TLS
  // challenge fires, so no challenge delegate is wired here. When
  // the Server isn't running the URL is nil and we fall through to
  // in-process rendering.
}
