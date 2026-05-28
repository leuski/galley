import Foundation
import HTTPTypes
import GalleyCoreKit

enum HTTPResponses {
  static func badRequest(_ message: String) -> Response {
    plainText(status: .badRequest, message: message)
  }

  static func notFound(_ message: String) -> Response {
    plainText(status: .notFound, message: message)
  }

  static func forbidden(_ message: String) -> Response {
    plainText(status: .forbidden, message: message)
  }

  static func unavailable() -> Response {
    plainText(
      status: .serviceUnavailable,
      message: String(
        localized: "Server is not ready.", bundle: .galleyServerKit))
  }

  static func errorPage(
    title: String, detail: String, source: String) -> Response
  {
    let html = errorPageTemplate.substituting(substitutions: [
      "#TITLE#": title.htmlEscaped,
      "#DETAIL#": detail.htmlEscaped,
      "#SOURCE#": source.htmlEscaped
    ])
    return Response(
      status: .internalServerError,
      headers: [.contentType: "text/html; charset=utf-8"],
      body: ResponseBody(byteBuffer: ByteBuffer(string: html)))
  }

  private final class Helper {}

  private static let errorPageTemplate: String =
    Bundle(for: Helper.self).requiredString(
      forResource: "ErrorPage", withExtension: "html")

  private static func plainText(
    status: HTTPResponse.Status, message: String) -> Response
  {
    Response(
      status: status,
      headers: [.contentType: "text/plain; charset=utf-8"],
      body: ResponseBody(byteBuffer: ByteBuffer(string: message + "\n")))
  }
}
