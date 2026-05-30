import Foundation
import KosmosAppKit

extension Response {
  static func errorPage(
    title: String.LocalizationValue,
    detail: String.LocalizationValue,
    source: String) -> Response
  {
    errorPage(
      title: String(localized: title, bundle: .galleyServerKit),
      detail: String(localized: detail, bundle: .galleyServerKit),
      source: source)
  }

  @_disfavoredOverload
  static func errorPage(
    title: String.LocalizationValue,
    detail: String,
    source: String) -> Response
  {
    errorPage(
      title: String(localized: title, bundle: .galleyServerKit),
      detail: detail,
      source: source)
  }

  @_disfavoredOverload
  private static func errorPage(
    title: String,
    detail: String,
    source: String) -> Response
  {
    internalServerError(errorPageTemplate.substituting(substitutions: [
      "#TITLE#": title.htmlEscaped,
      "#DETAIL#": detail.htmlEscaped,
      "#SOURCE#": source.htmlEscaped
    ]))
  }

  private final class Helper {}

  private static let errorPageTemplate: String =
  Bundle.galleyServerKit.requiredString(
    forResource: "ErrorPage", withExtension: "html")
}

extension Response {
  public static func ok(
    _ message: String.LocalizationValue) -> Response
  {
    ok(message, bundle: .galleyServerKit)
  }

  public static func badRequest(
    _ message: String.LocalizationValue) -> Response
  {
    badRequest(message, bundle: .galleyServerKit)
  }

  public static func notFound(
    _ message: String.LocalizationValue) -> Response
  {
    notFound(message, bundle: .galleyServerKit)
  }

  public static func forbidden(
    _ message: String.LocalizationValue) -> Response
  {
    forbidden(message, bundle: .galleyServerKit)
  }

  public static func unavailable(
    _ message: String.LocalizationValue) -> Response
  {
    unavailable(message, bundle: .galleyServerKit)
  }

  public static func guarded(
    request: Request,
    hostURLProvider: @Sendable @escaping () async -> URL?,
    extraAllowedHostsProvider: @Sendable @escaping () async -> Set<String>,
    handler: @Sendable @escaping (Request, URL) async -> Response
  ) async -> Response {
    do {
      return try await .guardedRequest(
        request: request, hostURLProvider: hostURLProvider,
        extraAllowedHostsProvider: extraAllowedHostsProvider,
        handler: handler)
    } catch {
      return switch error {
      case .notReady: .unavailable("Service not ready")
      case .hostNotAllowed: .forbidden("Host header not allowed")
      case .crossSiteRequest: .forbidden("Cross-site request rejected")
      }
    }
  }
}
