import Foundation
import GalleyCoreKit
import GalleyServerKit
import KosmosBridge
import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "BridgeIdentity")

/// One per Server process. Materializes the HTTPS cert + key for the
/// preview server: generates them on first launch, reuses them on
/// subsequent launches, and regenerates when the cert is within the
/// configured renewal threshold of expiry. Files land at the same
/// paths the preview server already reads
/// (`server-cert.pem` / `server-key.pem` in
/// `GalleyConstants.applicationSupportDirectory`), so
/// `PreviewServer.tryLoadTLSConfiguration()` picks them up without any
/// change to GalleyServerKit.
enum BridgeIdentityProvisioning {
  /// One process-wide store, shared between cert provisioning at boot
  /// and the Kosmos link that publishes the cert SHA in
  /// `BridgeAdvertisement`. Wrapping a value to keep it `let`.
  static let store: BridgeIdentityStore = BridgeIdentityStore(
    directory: GalleyConstants.applicationSupportDirectory,
    commonName: "Galley Server",
    configuration: {
      var config = BridgeIdentityStore.Configuration.default
      config.certificateFilename = GalleyConstants.serverCertificateFilename
      config.privateKeyFilename = GalleyConstants.serverPrivateKeyFilename
      return config
    }())

  /// Ensures the cert + key files exist on disk before the preview
  /// server starts. Logs but never throws — a failure here means HTTPS
  /// stays disabled and the HTTP listener still serves on loopback,
  /// matching today's behavior when the user hadn't dropped their own
  /// PEMs in place.
  static func ensure() async {
    do {
      let identity = try await store.currentIdentity()
      log.notice("""
        Bridge identity ready sha=\
        \(identity.certificateSHA256.hexShort, privacy: .public) \
        expires=\(identity.notValidAfter, privacy: .public)
        """)
    } catch {
      log.error("""
        Bridge identity provisioning failed: \
        \(error.localizedDescription, privacy: .public). \
        HTTPS will be disabled until the next successful generation.
        """)
    }
  }
}

private extension Data {
  /// 8-char hex prefix — enough to disambiguate in logs, short enough
  /// that the log line stays readable.
  var hexShort: String {
    prefix(4).map { String(format: "%02x", $0) }.joined()
  }
}
