import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("ServerProbe classification")
struct ServerProbeClassificationTests {
  private let host = URL(string: "http://127.0.0.1:8089/")!

  // MARK: - HTTP response classification

  @Test("200 response is .running with the host URL")
  func twoHundredRunning() {
    let response = HTTPURLResponse(
      url: host, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    #expect(ServerProbe.classify(response: response, host: host)
            == .running(host))
  }

  @Test("Every 2xx is .running",
        arguments: [200, 201, 202, 204, 226, 299])
  func anyTwoHundredRunning(code: Int) {
    let response = HTTPURLResponse(
      url: host, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    #expect(ServerProbe.classify(response: response, host: host)
            == .running(host))
  }

  @Test("3xx redirect classifies as .notResponding (server is up but odd)")
  func redirectNotResponding() {
    let response = HTTPURLResponse(
      url: host, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: nil)!
    #expect(ServerProbe.classify(response: response, host: host)
            == .notResponding)
  }

  @Test("4xx response is .notResponding",
        arguments: [400, 401, 403, 404, 418])
  func clientErrorNotResponding(code: Int) {
    let response = HTTPURLResponse(
      url: host, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    #expect(ServerProbe.classify(response: response, host: host)
            == .notResponding)
  }

  @Test("5xx response is .notResponding",
        arguments: [500, 502, 503])
  func serverErrorNotResponding(code: Int) {
    let response = HTTPURLResponse(
      url: host, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    #expect(ServerProbe.classify(response: response, host: host)
            == .notResponding)
  }

  @Test("Non-HTTP response classifies as .notResponding")
  func nonHTTPResponseNotResponding() {
    let response = URLResponse(
      url: host, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    #expect(ServerProbe.classify(response: response, host: host)
            == .notResponding)
  }

  // MARK: - URLError classification

  @Test("cannotConnectToHost (ECONNREFUSED) classifies as .stopped")
  func connectionRefusedStopped() {
    #expect(ServerProbe.classify(error: URLError(.cannotConnectToHost))
            == .stopped)
  }

  @Test("Timeout classifies as .notResponding")
  func timeoutNotResponding() {
    #expect(ServerProbe.classify(error: URLError(.timedOut))
            == .notResponding)
  }

  @Test("Other URLErrors classify as .notResponding",
        arguments: [
          URLError.Code.cannotFindHost,
          .networkConnectionLost,
          .notConnectedToInternet,
          .badServerResponse,
          .dnsLookupFailed
        ])
  func otherErrorsNotResponding(code: URLError.Code) {
    #expect(ServerProbe.classify(error: URLError(code)) == .notResponding)
  }
}

@Suite("ServerProbe startup grace mapping")
struct ServerProbeStartupGraceTests {
  private let host = URL(string: "http://127.0.0.1:8089/")!

  @Test("First .stopped within grace becomes .starting")
  func firstStoppedBecomesStarting() {
    var grace = 2
    let mapped = applyStartupGrace(
      .stopped, graceRemaining: &grace)
    #expect(mapped == .starting)
    #expect(grace == 1)
  }

  @Test("First .notResponding within grace becomes .starting")
  func firstNotRespondingBecomesStarting() {
    var grace = 2
    let mapped = applyStartupGrace(
      .notResponding, graceRemaining: &grace)
    #expect(mapped == .starting)
    #expect(grace == 1)
  }

  @Test("Two consecutive .stopped consume the entire grace budget")
  func twoStoppedConsumeGrace() {
    var grace = 2
    let first = applyStartupGrace(
      .stopped, graceRemaining: &grace)
    let second = applyStartupGrace(
      .stopped, graceRemaining: &grace)
    let third = applyStartupGrace(
      .stopped, graceRemaining: &grace)
    #expect(first == .starting)
    #expect(second == .starting)
    #expect(third == .stopped)
    #expect(grace == 0)
  }

  @Test("Grace budget covers a mix of .stopped and .notResponding")
  func mixedStoppedAndNotResponding() {
    var grace = 2
    let first = applyStartupGrace(
      .stopped, graceRemaining: &grace)
    let second = applyStartupGrace(
      .notResponding, graceRemaining: &grace)
    let third = applyStartupGrace(
      .notResponding, graceRemaining: &grace)
    #expect(first == .starting)
    #expect(second == .starting)
    #expect(third == .notResponding)
  }

  @Test(".running passes through and does not consume grace")
  func runningDoesNotConsumeGrace() {
    var grace = 2
    let mapped = applyStartupGrace(
      .running(host), graceRemaining: &grace)
    #expect(mapped == .running(host))
    #expect(grace == 2)
  }

  @Test("Grace counter of zero passes statuses through unchanged")
  func zeroGraceNoMapping() {
    var grace = 0
    let stopped = applyStartupGrace(
      .stopped, graceRemaining: &grace)
    let notResponding = applyStartupGrace(
      .notResponding, graceRemaining: &grace)
    #expect(stopped == .stopped)
    #expect(notResponding == .notResponding)
    #expect(grace == 0)
  }

  @Test(".starting and .unknown pass through unchanged")
  func nonProbeStatusesPassThrough() {
    var grace = 2
    let starting = applyStartupGrace(
      .starting, graceRemaining: &grace)
    let unknown = applyStartupGrace(
      .unknown, graceRemaining: &grace)
    #expect(starting == .starting)
    #expect(unknown == .unknown)
    #expect(grace == 2)
  }
}
