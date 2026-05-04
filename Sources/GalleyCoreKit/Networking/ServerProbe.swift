import Foundation

/// Probes the Markdown Preview Server's `GET /` route on a fixed
/// cadence and yields the resulting `ServerStatus`. Used by the
/// Viewer's settings pane to drive the status pill.
///
/// Modeled as an `AsyncSequence`: each `next()` runs one probe and
/// returns the resulting `ServerStatus`; the iterator owns the
/// poll-interval sleep between iterations. Pure poller — no UX
/// semantics like "starting grace" live here; callers layer that
/// on top.
public struct ServerProbe: AsyncSequence, Sendable {
  public typealias Element = ServerStatus

  private let host: URL
  private let session: URLSession
  private let timeout: TimeInterval
  private let pollInterval: Duration

  public init(
    host: URL,
    timeout: TimeInterval = 1.0,
    pollInterval: Duration = .seconds(2))
  {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.httpAdditionalHeaders = ["Sec-Fetch-Site": "same-origin"]
    self.host = host
    self.session = URLSession(configuration: config)
    self.timeout = timeout
    self.pollInterval = pollInterval
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      host: host,
      session: session,
      timeout: timeout,
      pollInterval: pollInterval)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let host: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let pollInterval: Duration
    private var hasEmitted: Bool = false

    init(
      host: URL,
      session: URLSession,
      timeout: TimeInterval,
      pollInterval: Duration)
    {
      self.host = host
      self.session = session
      self.timeout = timeout
      self.pollInterval = pollInterval
    }

    public mutating func next() async -> ServerStatus? {
      if hasEmitted {
        do {
          try await Task.sleep(for: pollInterval)
        } catch {
          return nil
        }
      }
      hasEmitted = true
      if Task.isCancelled { return nil }
      return await Self.probeOnce(
        host: host, session: session, timeout: timeout)
    }

    private static func probeOnce(
      host: URL,
      session: URLSession,
      timeout: TimeInterval
    ) async -> ServerStatus {
      var request = URLRequest(url: host)
      request.httpMethod = "GET"
      request.timeoutInterval = timeout
      do {
        let (_, response) = try await session.data(for: request)
        return ServerProbe.classify(response: response, host: host)
      } catch let error as URLError {
        return ServerProbe.classify(error: error)
      } catch {
        return .notResponding
      }
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

/// Maps the first `graceRemaining` `.stopped`/`.notResponding`
/// observations to `.starting` and decrements the counter. Other
/// statuses pass through untouched. Pure; lives next to
/// `ServerProbe` so callers polling the server can layer
/// "still-starting-up" UX on top of raw probe output.
///
/// Designed for the toggle-lifecycle case in the Viewer settings:
/// reset `graceRemaining` to the desired budget at the start of
/// every fresh probe loop (i.e. each time the user toggles the
/// server back on), then apply this on each yielded status.
public func applyStartupGrace(
  _ status: ServerStatus,
  graceRemaining: inout Int) -> ServerStatus
{
  switch status {
  case .stopped, .notResponding:
    guard graceRemaining > 0 else { return status }
    graceRemaining -= 1
    return .starting
  case .unknown, .disabled, .starting, .running:
    return status
  }
}
