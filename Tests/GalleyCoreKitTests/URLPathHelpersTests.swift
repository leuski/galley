import Foundation
import Testing

import GalleyCoreKit
internal import ALFoundation

@Suite("URL path helpers")
struct URLPathHelpersTests {
  private let base: URL = "http://127.0.0.1:8089"

  @Test("galleyPreview yields /preview")
  func previewBase() {
    #expect(
      base.galleyPreview.absoluteString
        == "http://127.0.0.1:8089/preview")
  }

  @Test("appendingPreview with absolute document path encodes spaces")
  func previewWithDocument() {
    #expect(
      base
        .appendingPreview(
          URL(fileURLWithPath: "/Users/foo/My Notes/test.md")
        ).absoluteString
        == "http://127.0.0.1:8089/preview/Users/foo/My%20Notes/test.md"
)
  }

  @Test("galleyTemplate yields /template/<id>")
  func templateBase() {
    #expect(
      base.galleyTemplate(id: "myth").absoluteString
        == "http://127.0.0.1:8089/template/myth")
  }

  @Test("galleyTemplate with file encodes id and file with spaces")
  func templateWithFile() {
    #expect(
      base.galleyTemplate(id: "My Theme").appending(path: "css/main.css")
        .absoluteString
        == "http://127.0.0.1:8089/template/My%20Theme/css/main.css")
  }
}
