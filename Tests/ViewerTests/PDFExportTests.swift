//
//  PDFExportTests.swift
//  Galley
//
//  Covers the shared `PDFExport` value type extracted into
//  `DocumentModel+PDFShared.swift`: the suggested filename is carried
//  through verbatim and the render closure is lazy (never invoked at
//  construction time).
//

import Foundation
import Testing
@testable import Galley

@MainActor
@Test("PDFExport carries the suggested name and defers rendering")
func pdfExportDefersRendering() async throws {
  var didRender = false
  let export = PDFExport(suggestedName: "MyDocument") {
    didRender = true
    return URL.temporaryDirectory.appending(component: "MyDocument.pdf")
  }

  #expect(export.suggestedName == "MyDocument")
  #expect(didRender == false)

  let url = try await export.render()
  #expect(didRender == true)
  #expect(url.lastPathComponent == "MyDocument.pdf")
}
