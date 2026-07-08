//
//  Modifiers.swift
//  Galley
//
//  Created by Anton Leuski on 6/17/26.
//

#if os(macOS)
import SwiftUI
import GalleyCoreKit
import UniformTypeIdentifiers

struct WindowAttachedModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .windowAccessor { window in
        // The window is always visible — no reveal gate. Resolve it
        // once to patch the AppKit tab-bar "+" (so a user "+" click
        // opens via the Open panel + activity URL). Help skips it.
        // Inbound-URL routing lives in `DocumentSceneContent`, not here.
        guard let window else { return }
        NewTabAction.install(on: window)
      }
  }
}

struct ExportModifier: ViewModifier {
  @Bindable var model: DocumentModel
  let appModel: AppModel

  /// Non-nil while the SwiftUI "Couldn't export PDF" alert is up.
  /// Set by the export flow on failure; cleared when the alert is
  /// dismissed.
  @State private var exportPDFError: String?

  /// Bridges the optional error string to the boolean the
  /// `.alert(... isPresented:)` modifier expects: clearing the error
  /// dismisses the alert and vice versa.
  private var exportPDFErrorPresented: Binding<Bool> {
    Binding(
      get: { exportPDFError != nil },
      set: { if !$0 { exportPDFError = nil } })
  }

  func body(content: Content) -> some View {
    content
      .alert(
        "Couldn’t export PDF",
        isPresented: exportPDFErrorPresented,
        presenting: exportPDFError
      ) { _ in
        Button("OK") { exportPDFError = nil }
      } message: { message in
        Text(message)
      }
      .fileExporter(
        isPresented: $model.isExportingPDF,
        item: model.pdfExport(),
        contentTypes: [.pdf],
        defaultFilename: model.documentURL
          .deletingPathExtension().lastPathComponent
      ) { result in
        if case .failure(let error) = result {
          exportPDFError = error.localizedDescription
        }
      }
      .fileDialogDefaultDirectory(
        model.documentURL.parent)
  }
}

import OSLog

private let log = Logger(
  subsystem: bundleIdentifier, category: "DocumentView")

struct RenameModifier: ViewModifier {
  @Bindable var model: DocumentModel
  /// Transient text-field value for the rename alert. Seeded from
  /// `model.documentURL.lastPathComponent` whenever
  /// `model.isRenameRequested` flips true (see the `.onChange` in
  /// `body`). Lives on the view because it has no meaning outside
  /// the alert's lifetime.
  @State private var renameInput = ""
  let appModel: AppModel
  private var recents: RecentDocumentsModel { appModel.recents }

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename Document",
        isPresented: $model.isRenameRequested
      ) {
        TextField(
          model.documentURL.lastPathComponent, text: $renameInput)
        Button("Rename") { performRename() }
        Button("Cancel", role: .cancel) { }
      } message: {
        Text("Enter a new file name for this document.")
      }
      .onChange(of: model.isRenameRequested) { _, new in
        if new { renameInput = model.documentURL.lastPathComponent }
      }
  }

  /// Run the rename triggered by the SwiftUI alert's "Rename" button.
  /// Trims whitespace, no-ops on empty / unchanged input, beeps on
  /// failure (matches the prior NSAlert flow), and on success records
  /// the renamed URL with Open Recent and follows the WindowGroup
  /// binding to the new path.
  private func performRename() {
    let trimmed = renameInput
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let currentURL = model.documentURL
    guard !trimmed.isEmpty, trimmed != currentURL.lastPathComponent
    else { return }
    Task { @MainActor in
      do {
        let newURL = try await model.renameCurrentDocument(toName: trimmed)
        recents.record(newURL)
      } catch {
        // `renameCurrentDocument` already posted a notice banner via
        // `report(failure:)`. Beep matches the prior NSAlert UX; log
        // the underlying error so support reports retain context.
        log.error("""
          Rename failed for \(model.documentURL.path, privacy: .private): \
          \(error.localizedDescription, privacy: .public)
          """)
        NSSound.beep()
      }
    }
  }
}

#endif
