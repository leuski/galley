import Foundation
import GalleyCoreKit

extension Response {
  static func forbidden(
    _ message: String.LocalizationValue) -> Response
  {
    forbidden(message, bundle: .galleyServerKit)
  }

  static func unavailable(
    _ message: String.LocalizationValue) -> Response
  {
    unavailable(message, bundle: .galleyServerKit)
  }

  /// Host-guard wrapper. The guard runs *before* the transport-neutral
  /// `PreviewRequestService`, so its failures are HTTP-listener-specific
  /// (DNS-rebinding / cross-site checks) and stay here rather than in the
  /// shared `PreviewResponseShaper`.
  static func guarded(
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
