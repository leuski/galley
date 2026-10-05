//
//  HTMLHeadingsTests.swift
//  Galley
//

import Foundation
import Testing
@testable import GalleyCoreKit

@Suite("HTMLHeadings")
struct HTMLHeadingsTests {
  @Test("First H1 text skips the TeX annotation inside MathML")
  func firstH1SkipsMathAnnotation() {
    let body = """
      <h1 data-source-line="1">Euler <span class="math inline"><math>\
      <semantics><msup><mi>x</mi><mn>2</mn></msup>\
      <annotation encoding="application/x-tex">x^2</annotation>\
      </semantics></math></span></h1>
      <p>body</p>
      """

    #expect(HTMLHeadings.firstH1Text(in: body) == "Euler x2")
  }

  @Test("First H1 text strips inline formatting and decodes entities")
  func firstH1Plain() {
    let body = "<h1><em>A</em> &amp; <code>b</code></h1>"

    #expect(HTMLHeadings.firstH1Text(in: body) == "A & b")
  }
}
