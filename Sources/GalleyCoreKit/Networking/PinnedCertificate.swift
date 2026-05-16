import Foundation
import CryptoKit
import Security
import ALFoundation

/// Certificate pinning for the Viewer + Quicklook → Galley Server
/// HTTPS channel. The server publishes its public cert at
/// `~/Library/Application Support/net.leuski.galley.localized/server-cert.pem`;
/// consumers compute a SHA-256 pin from the file and compare it to
/// the leaf certificate the server presents during the TLS
/// handshake.
///
/// We pin the full leaf-cert DER (not SPKI) for Phase 1 simplicity.
/// Rotating the cert means rotating both files at once — fine for a
/// dev-only self-signed setup. SPKI pinning is the upgrade path if
/// cert rotation ever needs to outlive key rotation.
///
/// The file is re-read on every pin check. It's small (~1 KB) and
/// the hash is cheap; skipping a cache means a cert swap takes
/// effect on the next request without restarting the consumer.
public enum PinnedCertificate {
  /// SHA-256 digest of the leaf certificate's DER bytes.
  public typealias Pin = Data

  public static var certificateURL: URL {
    GalleyConstants.applicationSupportDirectory / "server-cert.pem"
  }

  /// Returns the pin for the currently-published cert, or nil if
  /// the file is missing or doesn't contain a parseable CERTIFICATE
  /// block. nil propagates through `matches(serverTrust:)` to a
  /// rejection — the secure default when we don't know what to
  /// trust.
  public static func loadPin() -> Pin? {
    guard let pem = try? String(
      contentsOf: certificateURL, encoding: .utf8),
      let der = decodePEMCertificate(pem)
    else { return nil }
    return Data(SHA256.hash(data: der))
  }

  /// Extracts the DER bytes from the first CERTIFICATE block in a
  /// PEM string. Returns nil when the markers are missing or the
  /// base64 payload doesn't decode. Internal so unit tests can
  /// exercise the parser without touching the filesystem.
  static func decodePEMCertificate(_ pem: String) -> Data? {
    let begin = "-----BEGIN CERTIFICATE-----"
    let end = "-----END CERTIFICATE-----"
    guard let beginRange = pem.range(of: begin) else { return nil }
    guard let endRange = pem.range(
      of: end,
      range: beginRange.upperBound..<pem.endIndex)
    else { return nil }
    let body = pem[beginRange.upperBound..<endRange.lowerBound]
    let base64 = body
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    return Data(base64Encoded: base64)
  }

  /// True if the leaf certificate of `serverTrust` hashes to the
  /// currently-stored pin. Returns false (cancel the connection)
  /// when either the pin file or the trust chain is missing — never
  /// silently accept.
  public static func matches(serverTrust: SecTrust) -> Bool {
    guard let pin = loadPin() else { return false }
    guard let chain = SecTrustCopyCertificateChain(serverTrust)
      as? [SecCertificate],
      let leaf = chain.first
    else { return false }
    let leafDER = SecCertificateCopyData(leaf) as Data
    let leafHash = Data(SHA256.hash(data: leafDER))
    return leafHash == pin
  }
}
