//
//  ExportPDFTests.swift
//  Galley
//
//  Runs the real Export-as-PDF path (offscreen WKWebView →
//  NSPrintOperation with a `.save` disposition) and checks that the
//  returned URL is a PDF that exists *when `exportPDF` returns*.
//  Regression: `runModal(for:…)` returns before the spool is written,
//  so returning the destination immediately handed SwiftUI's exporter
//  a path with no file behind it ("couldn't be opened because there is
//  no such file") and the user got an empty export.
//

#if os(macOS)
import Foundation
import GalleyCoreKit
import Testing
@testable import Galley

@MainActor
@Suite("Export as PDF")
struct ExportPDFTests {
  @Test("exportPDF returns a URL whose PDF already exists on disk")
  func exportWritesFileBeforeReturning() async throws {
    let source = URL.temporaryDirectory / "export-\(UUID().uuidString).md"
    let body = (1...120).map { "Paragraph \($0) with some text." }
      .joined(separator: "\n\n")
    try "# Export probe\n\n\(body)\n".write(
      to: source, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: source) }
    let model = DocumentModel(appModel: AppModel.shared, url: source)

    let pdf = try await model.exportPDF()
    defer { try? FileManager.default.removeItem(at: pdf) }

    #expect(pdf.pathExtension == "pdf")
    #expect(pdf.itemExists)
    let data = try Data(contentsOf: pdf)
    #expect(data.count > 1_000)
    #expect(data.prefix(5) == Data("%PDF-".utf8))
  }
}
#endif
