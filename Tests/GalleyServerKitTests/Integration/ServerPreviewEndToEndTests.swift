#if os(macOS)
import Foundation
import Testing
import GalleyCoreKit
internal import ALFoundation
@testable import GalleyServerKit

/// End-to-end tests that actually bind a TCP socket and round-trip
/// through `URLSession`. These are slower than the unit suites
/// (~100–500 ms each) and must run serialized — they reuse a port
/// across tests, and `controller.stop()` is fire-and-forget on the
/// socket close. Documents the real "does it serve a page?" path.
@Suite("Server preview end-to-end", .serialized)
@MainActor
struct ServerPreviewEndToEndTests {
  // MARK: - Fixtures

  /// Creates a fresh temp directory and `Hello.md` inside it. Returns
  /// the file URL. The directory is auto-removed on test exit via
  /// the `Confirmation` cleanup pattern below.
  private func makeTempMarkdownFile(
    contents: String = "# Hello\n\nWorld\n"
  ) throws -> URL {
    let dir = URL.temporaryDirectory / "galley-e2e-\(UUID().uuidString)"
    try dir.createDirectory()
    let file = dir / "Hello.md"
    try Data(contents.utf8).write(to: file)
    return file
  }

  /// Spins up a controller, waits until `state == .running` (polled
  /// at 50 ms intervals), and returns the running controller plus
  /// the auto-assigned host URL. Calls `Issue.record` and returns
  /// nil on timeout / failure.
  private func startReadyController(
    renderer: any MarkdownRenderer = SwiftMarkdownRenderer()
  ) async -> (PreviewServerController, URL)? {
    let controller = PreviewServerController()
    controller.start(
      service: PreviewRequestService(
        selectedTemplate: { Template.default },
        renderer: { renderer }),
      watcher: DocumentWatcher(),
      host: "127.0.0.1")

    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      switch controller.state {
      case .running(let url):
        return (controller, url)
      case .failed(let message):
        Issue.record("Server failed to start: \(message)")
        return nil
      case .stopped:
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    Issue.record("""
      Server did not reach .running within 3s; final state \(controller.state)
      """)
    controller.stop()
    return nil
  }

  /// `controller.stop()` schedules the close on a detached Task. Give
  /// the kernel a moment to actually release the port before the next
  /// test rebinds it.
  private func cleanup(_ controller: PreviewServerController) async {
    controller.stop()
    try? await Task.sleep(for: .milliseconds(150))
  }

  /// `URLSession.shared` adds caching headers we don't want in tests;
  /// use an ephemeral session per request.
  private func get(_ url: URL) async throws -> (Int, String) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: config)
    let (data, response) = try await session.data(for: URLRequest(url: url))
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? -1
    let body = String(data: data, encoding: .utf8) ?? ""
    return (status, body)
  }

  // MARK: - Tests

  @Test("GET /preview/<tempfile> returns 200 + rendered HTML")
  func rendersTempMarkdown() async throws {
    let file = try makeTempMarkdownFile()
    defer { try? file.parent.remove() }

    guard let (controller, host) = await startReadyController() else { return }
    defer { Task { @MainActor in await cleanup(controller) } }

    let previewURL = host.appendingPreview(file)
    let (status, body) = try await get(previewURL)

    #expect(status == 200, "Body was: \(body.prefix(500))")
    // SwiftMarkdownRenderer wraps the H1 in <h1>…</h1>; the template
    // wraps the body in #DOCUMENT_CONTENT#. So rendered output should
    // contain both the heading and the paragraph text.
    #expect(body.contains("<h1"), "Missing rendered <h1>")
    #expect(body.contains("Hello"), "Missing heading text")
    #expect(body.contains("World"), "Missing paragraph text")
    // Live-reload script is injected before </body>.
    #expect(body.contains("EventSource"), "Missing live-reload script")
  }

  @Test("GET /preview/<missing> returns 404 with 'Cannot read'")
  func missingFileReturnsNotFound() async throws {
    guard let (controller, host) = await startReadyController() else { return }
    defer { Task { @MainActor in await cleanup(controller) } }

    let bogus = "/tmp/galley-e2e-does-not-exist-\(UUID().uuidString).md"
    let previewURL = host.appendingPreview(URL(fileURLWithPath: bogus))
    let (status, body) = try await get(previewURL)

    #expect(status == 404)
    #expect(body.contains("Cannot read"))
    #expect(body.contains(bogus))
  }

  @Test("Path with a space in it round-trips correctly")
  func pathWithSpaceRoundTrips() async throws {
    let dir = URL.temporaryDirectory / "galley-e2e-\(UUID().uuidString)"
    try dir.createDirectory()
    defer { try? dir.remove() }

    let file = dir / "My Notes.md"
    try Data("# Spaced\n\nText\n".utf8).write(to: file)

    guard let (controller, host) = await startReadyController() else { return }
    defer { Task { @MainActor in await cleanup(controller) } }

    let previewURL = host.appendingPreview(file)
    let (status, body) = try await get(previewURL)

    #expect(status == 200, "Body was: \(body.prefix(500))")
    #expect(body.contains("Spaced"))
  }
}
#endif
