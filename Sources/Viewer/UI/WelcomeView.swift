//
//  WelcomeView.swift
//  Galley
//
//  Shared (macOS + visionOS) landing surface for a window with no
//  document. Replaces the macOS invisible-bootstrap + FTUE panel and
//  VisionWelcomeScreen. Opening a document always fires an activity URL
//  (the open dialog included) so welcome → document goes through the
//  same dispatch path as any other open.
//

import GalleyCoreKit
import SwiftUI

struct WelcomeView: View {
  private var recents: RecentDocumentsModel { AppModel.shared.recents }

#if !os(macOS)
  @State private var isImporting = false
#endif

  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 8) {
        Image(systemName: "doc.richtext")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        Text("Galley")
          .font(.largeTitle.bold())
      }

      Button("Open Document…", action: openDocument)
        .buttonStyle(.borderedProminent)

      if !recents.urls.isEmpty {
        recentsList
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
#if !os(macOS)
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: MarkdownFileTypes.allTypesAndPlainText,
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        GalleyViewerRequestActivity(url: url).open()
      }
    }
#endif
  }

  private var recentsList: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Recent")
        .font(.headline)
        .foregroundStyle(.secondary)
      ForEach(recents.urls.prefix(8), id: \.self) { url in
        Button {
          openRecent(url)
        } label: {
          Label(url.lastPathComponent, systemImage: "doc")
            .lineLimit(1)
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: 360, alignment: .leading)
  }

  private func openDocument() {
#if os(macOS)
    recents.presentOpenPanel()
#else
    isImporting = true
#endif
  }

  private func openRecent(_ url: URL) {
#if os(macOS)
    GalleyViewerRequestActivity(url: url).open()
#else
    // visionOS recents are security-scoped bookmarks — re-resolve to a
    // fresh accessible URL before dispatching.
    if let resolved = recents.resolveRecentURL(url) {
      GalleyViewerRequestActivity(url: resolved).open()
    }
#endif
  }
}
