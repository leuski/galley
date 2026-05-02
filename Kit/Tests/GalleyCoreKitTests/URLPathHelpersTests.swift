import Foundation
import Testing

import GalleyCoreKit
internal import ALFoundation

@Suite("URL path helpers")
struct URLPathHelpersTests {
  private let base: URL = "http://127.0.0.1:8089"

  @Test("appendingPreviewPath without arg yields /preview")
  func previewBase() {
    #expect(
      base.appendingPreviewPath().absoluteString
        == "http://127.0.0.1:8089/preview")
  }

  @Test("appendingPreviewPath with absolute document path encodes spaces")
  func previewWithDocument() {
    #expect(
      base.appendingPreviewPath("/Users/foo/My Notes/test.md").absoluteString
        == "http://127.0.0.1:8089/preview/Users/foo/My%20Notes/test.md")
  }

  @Test("appendingTemplatePath without file yields /template/<id>")
  func templateBase() {
    #expect(
      base.appendingTemplatePath(id: "myth").absoluteString
        == "http://127.0.0.1:8089/template/myth")
  }

  @Test("appendingTemplatePath encodes id and file with spaces")
  func templateWithFile() {
    #expect(
      base.appendingTemplatePath(id: "My Theme", file: "css/main.css")
        .absoluteString
        == "http://127.0.0.1:8089/template/My%20Theme/css/main.css")
  }
}
