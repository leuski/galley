import Foundation
import Testing

import GalleyCoreKit
internal import ALFoundation

@Suite("URL path helpers")
struct URLPathHelpersTests {
  private let base: URL = "http://127.0.0.1:8089"

  @Test("documentAsset encodes the absolute path under /preview")
  func documentAsset() {
    #expect(
      base.appending(.documentAsset(
        URL(fileURLWithPath: "/Users/foo/My Notes/test.md")))
        .absoluteString
        == "http://127.0.0.1:8089/preview/Users/foo/My%20Notes/test.md")
  }

  @Test("templateAsset encodes id and file under /template")
  func templateAsset() {
    #expect(
      base.appending(.templateAsset(
        id: .init(rawValue: "My Theme"), file: "css/main.css"))
        .absoluteString
        == "http://127.0.0.1:8089/template/My%20Theme/css/main.css")
  }

  @Test("events encodes the absolute path under /events")
  func eventsAsset() {
    #expect(
      base.appending(.events(
        URL(fileURLWithPath: "/Users/foo/doc.md")))
        .absoluteString
        == "http://127.0.0.1:8089/events/Users/foo/doc.md")
  }
}
