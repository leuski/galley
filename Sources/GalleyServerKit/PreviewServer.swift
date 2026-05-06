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

  public func start(url: URL) {
    stop()

    let templateProvider = selectedTemplateProvider
    let provider = rendererProvider
    let watcher = self.watcher

    guard let components = URLComponents(
      url: url, resolvingAgainstBaseURL: false)
    else {
      state = .failed(
        message: String(
          localized: "Cannot resolve url: \(url.absoluteString)",
          bundle: .galleyServerKit))
      return
    }

    let host = components.host ?? GalleyConstants.defaultHost
    let port = components.port.map { port in UInt16(port) }
    ?? GalleyConstants.defaultPort

    var fullComponents = URLComponents()
    fullComponents.scheme = "http"
    fullComponents.host = host
    fullComponents.port = Int(port)

    guard let fullURL = components.url else {
      state = .failed(
        message: String(
          localized: "Cannot resolve url: \(String(describing: components))",
          bundle: .galleyServerKit))
      return
    }

    let address: sockaddr_in
    do {
      address = try sockaddr_in.inet(ip4: host, port: port)
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
        hostURL: fullURL,
        selectedTemplateProvider: templateProvider,
        rendererProvider: provider,
        watcher: watcher)

      do {
        self?.publish(state: .running(url: fullURL))
        try await server.run()
        self?.publish(state: .stopped)
      } catch {
        self?.publish(state: .failed(message: error.localizedDescription))
      }
    }
  }

  public func stop() {
    Task { [server] in
      await server?.stop()
    }
    server = nil
    state = .stopped
  }

  nonisolated private func publish(state: State) {
    Task { @MainActor [weak self] in
      self?.state = state
    }
  }

  public var serverURL: URL? {
    guard case .running(let url) = state else { return nil }
    return url
  }
}
