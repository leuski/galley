import Foundation
import FlyingFox
import GalleyCoreKit

enum HTTPResponses {
  static func badRequest(_ message: String) -> HTTPResponse {
    plainText(statusCode: .badRequest, message: message)
  }

  static func notFound(_ message: String) -> HTTPResponse {
    plainText(statusCode: .notFound, message: message)
  }

  static func forbidden(_ message: String) -> HTTPResponse {
    plainText(statusCode: .forbidden, message: message)
  }

  static func unavailable() -> HTTPResponse {
    plainText(
      statusCode: .serviceUnavailable,
      message: String(
        localized: "Server is not ready.", bundle: .galleyServerKit))
  }

  static func errorPage(
    title: String, detail: String, source: String) -> HTTPResponse
  {
    let html = errorPageTemplate.substituting(substitutions: [
      "#TITLE#": title.htmlEscaped,
      "#DETAIL#": detail.htmlEscaped,
      "#SOURCE#": source.htmlEscaped
    ])
    return HTTPResponse(
      statusCode: .internalServerError,
      headers: [.contentType: "text/html; charset=utf-8"],
      body: Data(html.utf8))
  }

  private final class Helper {}

  private static let errorPageTemplate: String =
  Bundle(for: Helper.self).requiredString(
      forResource: "ErrorPage", withExtension: "html")

  private static func plainText(
    statusCode: HTTPStatusCode, message: String) -> HTTPResponse
  {
    HTTPResponse(
      statusCode: statusCode,
      headers: [.contentType: "text/plain; charset=utf-8"],
      body: Data((message + "\n").utf8))
  }

}
