import Foundation

/// Probes the Markdown Preview Server's `GET /` route to determine
/// whether it is actually listening, regardless of what the
/// `SMAppService` registration status says. Used by the Viewer's
/// settings pane to drive the status pill.
public struct ServerProbe: Sendable {
  private let session: URLSession
  private let timeout: TimeInterval

  public init(timeout: TimeInterval = 1.0) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.httpAdditionalHeaders = ["Sec-Fetch-Site": "same-origin"]
    self.session = URLSession(configuration: config)
    self.timeout = timeout
  }

  public func probe(host: URL) async -> ServerStatus {
    var request = URLRequest(url: host)
    request.httpMethod = "GET"
    request.timeoutInterval = timeout
    do {
      let (_, response) = try await session.data(for: request)
      return Self.classify(response: response, host: host)
    } catch let error as URLError {
      return Self.classify(error: error)
    } catch {
      return .notResponding
    }
  }

  /// 2xx → `.running(host)`; anything else → `.notResponding`. Pure;
  /// extracted for unit testing without standing up a real server.
  public static func classify(
    response: URLResponse, host: URL) -> ServerStatus
  {
    guard let http = response as? HTTPURLResponse else {
      return .notResponding
    }
    return (200..<300).contains(http.statusCode)
      ? .running(host)
      : .notResponding
  }

  /// `cannotConnectToHost` is what `URLSession` reports for a TCP
  /// `ECONNREFUSED` — the canonical signal that the Server isn't
  /// listening. Every other `URLError` is treated as `.notResponding`.
  /// Pure; extracted for unit testing.
  public static func classify(error: URLError) -> ServerStatus {
    switch error.code {
    case .cannotConnectToHost:
      return .stopped
    default:
      return .notResponding
    }
  }
}
