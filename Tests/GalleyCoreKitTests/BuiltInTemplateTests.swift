import Foundation
import Testing
import GalleyCoreKit
internal import ALFoundation

@Suite("BuiltInTemplate")
struct BuiltInTemplateTests {
  private let origin: URL = "http://127.0.0.1:8089"

  @Test("rewriteAssets returns html unchanged")
  func rewriteIsNoOp() {
    let html = #"<link href="anything.css">"#
    let out = BuiltInTemplate.shared.rewriteAssets(in: html, origin: origin)
    #expect(out == html)
  }

  @Test("resolveAsset always returns nil")
  func resolveIsNil() {
    #expect(BuiltInTemplate.shared.resolveAsset(file: "x.css") == nil)
  }

  @Test("loadHTML returns the bundled DefaultTemplate (non-empty)")
  func loadsBundledHTML() throws {
    let html = try BuiltInTemplate.shared.loadHTML()
    #expect(!html.isEmpty)
  }
}
