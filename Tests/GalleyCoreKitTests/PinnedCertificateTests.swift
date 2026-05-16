import Foundation
import Testing
import CryptoKit
@testable import GalleyCoreKit
internal import ALFoundation

/// Unit tests for the pure parts of `PinnedCertificate`. The
/// `matches(serverTrust:)` path needs a live `SecTrust` and is
/// covered indirectly by an end-to-end TLS test elsewhere.
@Suite("PinnedCertificate")
struct PinnedCertificateTests {
  @Test("decodePEMCertificate extracts and base64-decodes the body")
  func decodesPEM() {
    // Arbitrary base64-encoded payload — the parser doesn't care
    // whether the bytes form a real X.509 cert, only that the PEM
    // framing parses and the body decodes.
    let pem = """
      -----BEGIN CERTIFICATE-----
      SGVsbG8gV29ybGQ=
      -----END CERTIFICATE-----
      """
    let der = PinnedCertificate.decodePEMCertificate(pem)
    #expect(der == Data("Hello World".utf8))
  }

  @Test("Multi-line base64 bodies are joined before decoding")
  func decodesMultiLinePEM() {
    let pem = """
      -----BEGIN CERTIFICATE-----
      SGVsbG8g
      V29ybGQ=
      -----END CERTIFICATE-----
      """
    let der = PinnedCertificate.decodePEMCertificate(pem)
    #expect(der == Data("Hello World".utf8))
  }

  @Test("Missing BEGIN marker returns nil")
  func missingBeginReturnsNil() {
    let pem = """
      SGVsbG8gV29ybGQ=
      -----END CERTIFICATE-----
      """
    #expect(PinnedCertificate.decodePEMCertificate(pem) == nil)
  }

  @Test("Missing END marker returns nil")
  func missingEndReturnsNil() {
    let pem = """
      -----BEGIN CERTIFICATE-----
      SGVsbG8gV29ybGQ=
      """
    #expect(PinnedCertificate.decodePEMCertificate(pem) == nil)
  }

  @Test("Garbage base64 in the body returns nil")
  func invalidBase64ReturnsNil() {
    let pem = """
      -----BEGIN CERTIFICATE-----
      this is not base64 @@@
      -----END CERTIFICATE-----
      """
    #expect(PinnedCertificate.decodePEMCertificate(pem) == nil)
  }

  @Test("loadPin reads the on-disk cert and returns SHA-256 of its DER")
  func loadPinHashesDER() throws {
    let snap = try? Data(contentsOf: PinnedCertificate.certificateURL)
    defer {
      if let snap {
        try? snap.write(to: PinnedCertificate.certificateURL)
      } else {
        try? FileManager.default.removeItem(
          at: PinnedCertificate.certificateURL)
      }
    }

    let body = Data("test-cert-body".utf8)
    let pem = """
      -----BEGIN CERTIFICATE-----
      \(body.base64EncodedString())
      -----END CERTIFICATE-----
      """
    try GalleyConstants.applicationSupportDirectory.createDirectory()
    try pem.write(
      to: PinnedCertificate.certificateURL,
      atomically: true,
      encoding: .utf8)

    let expected = Data(SHA256.hash(data: body))
    #expect(PinnedCertificate.loadPin() == expected)
  }

  @Test("loadPin returns nil when the file is missing")
  func loadPinNilWhenMissing() {
    let snap = try? Data(contentsOf: PinnedCertificate.certificateURL)
    defer {
      if let snap {
        try? snap.write(to: PinnedCertificate.certificateURL)
      }
    }
    try? FileManager.default.removeItem(at: PinnedCertificate.certificateURL)
    #expect(PinnedCertificate.loadPin() == nil)
  }
}
