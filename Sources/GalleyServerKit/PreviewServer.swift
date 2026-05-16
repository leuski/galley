import Foundation
import Observation
import FlyingFox
import FlyingSocks
import GalleyCoreKit

@Observable
@MainActor
public final class PreviewServerController {
  public enum State: Equatable, Sendable {
    case stopped
    case running(url: URL)
    case failed(message: String)
  }

  public private(set) var state: State = .stopped

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var server: HTTPServer?

  @ObservationIgnored public let watcher = DocumentWatcher()

  @ObservationIgnored private let selectedTemplateProvider: @Sendable ()
  async -> Template
  @ObservationIgnored private let rendererProvider: @Sendable ()
  async -> (any MarkdownRenderer)?

  public init(
    selectedTemplateProvider: @escaping @Sendable () async -> Template,
    rendererProvider: @escaping @Sendable () async -> (any MarkdownRenderer)?
  ) {
    self.selectedTemplateProvider = selectedTemplateProvider
    self.rendererProvider = rendererProvider
  }

  /// Binds to `127.0.0.1` on an OS-assigned port. After FlyingFox
  /// reports the listener is up, the actual port is queried via
  /// `listeningAddress` and written to `ServerPortFile` so consumers
  /// (Viewer probe, Quicklook, bundled scripts) can discover the
  /// endpoint. The port file is cleared on `stop()` and on listener
  /// failure so stale values don't outlive the process.
  public func start() {
    stop()

    let templateProvider = selectedTemplateProvider
    let provider = rendererProvider
    let watcher = self.watcher

    let address: sockaddr_in
    do {
      address = try sockaddr_in.inet(
        ip4: GalleyConstants.defaultHost, port: 0)
    } catch {
      state = .failed(message: String(
        localized: """
          Cannot create loopback address: \(error.localizedDescription)
          """,
        bundle: .galleyServerKit))
      return
    }
    let server = HTTPServer(address: address)
    self.server = server

    Task { [weak self] in
      await Routes.register(
        on: server,
        hostURLProvider: { await Self.endpointURL(for: server) },
        selectedTemplateProvider: templateProvider,
        rendererProvider: provider,
        watcher: watcher)

      let runTask = Task {
        do {
          try await server.run()
        } catch {
          await self?.publishFailure(error.localizedDescription)
        }
        await self?.publishStopped()
      }

      do {
        try await server.waitUntilListening(timeout: 5)
      } catch {
        await self?.publishFailure(error.localizedDescription)
        runTask.cancel()
        return
      }

      guard let endpoint = await Self.endpointURL(for: server),
        let port = await Self.boundPort(for: server)
      else {
        await self?.publishFailure(String(
          localized: "Server bound but reported no address.",
          bundle: .galleyServerKit))
        runTask.cancel()
        return
      }

      do {
        try ServerPortFile.write(port, for: .http)
      } catch {
        await self?.publishFailure(String(
          localized: """
            Cannot write port file: \(error.localizedDescription)
            """,
          bundle: .galleyServerKit))
        runTask.cancel()
        return
      }

      await self?.publishRunning(endpoint)
      _ = await runTask.value
    }
  }

  public func stop() {
    ServerPortFile.clear(for: .http)
    Task { [server] in
      await server?.stop()
    }
    server = nil
    state = .stopped
  }

  nonisolated private func publishRunning(_ url: URL) async {
    await MainActor.run { self.state = .running(url: url) }
  }

  nonisolated private func publishStopped() async {
    await MainActor.run {
      ServerPortFile.clear(for: .http)
      self.state = .stopped
    }
  }

  nonisolated private func publishFailure(_ message: String) async {
    await MainActor.run {
      ServerPortFile.clear(for: .http)
      self.state = .failed(message: message)
    }
  }

  public var serverURL: URL? {
    guard case .running(let url) = state else { return nil }
    return url
  }

  /// Reads the bound port from `listeningAddress`. Returns nil if
  /// the listener isn't up or bound a non-IPv4 socket.
  private static func boundPort(
    for server: HTTPServer) async -> UInt16?
  {
    guard let address = await server.listeningAddress else { return nil }
    if case .ip4(_, port: let port) = address { return port }
    return nil
  }

  /// Builds the `http://127.0.0.1:<bound-port>/` URL for a running
  /// listener. Returns nil if the listener isn't bound yet. Used by
  /// `Routes` to resolve relative URLs in template asset rewriting.
  private static func endpointURL(
    for server: HTTPServer) async -> URL?
  {
    guard let port = await boundPort(for: server) else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = GalleyConstants.defaultHost
    components.port = Int(port)
    return components.url
  }
}
