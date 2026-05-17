import Foundation
import WebKit
import GalleyCoreKit

/// `WebPage.NavigationDeciding` implementation that pins the Galley
/// Server HTTPS certificate. The Viewer's `WebPage` normally loads
/// in-process content through the `x-galley://local` scheme handler
/// — that path never produces a server-trust challenge. The pinner
/// engages only for `https://127.0.0.1:<port>/...` URLs that reach
/// the live HTTPS listener (e.g. asset references emitted by a
/// template that's been rewritten against the server origin, or any
/// future server-driven load path).
///
/// Pin material comes from
/// `~/Library/Application Support/net.leuski.galley.localized/server-cert.pem`
/// via `PinnedCertificate`. Re-reads on every challenge so a cert
/// rotation propagates without restarting the Viewer.
struct ServerCertificatePinner: WebPage.NavigationDeciding {
  func decideAuthenticationChallengeDisposition(
    for challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard
      challenge.protectionSpace.authenticationMethod
        == NSURLAuthenticationMethodServerTrust,
      let serverTrust = challenge.protectionSpace.serverTrust
    else {
      return (.performDefaultHandling, nil)
    }

    if PinnedCertificate.matches(serverTrust: serverTrust) {
      return (.useCredential, URLCredential(trust: serverTrust))
    }
    return (.cancelAuthenticationChallenge, nil)
  }
}
