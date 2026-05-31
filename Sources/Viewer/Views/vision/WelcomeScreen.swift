//
//  WelcomeScreen.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

import SwiftUI
import GalleyCoreKit

/// Landing surface shown when the WindowGroup binding has no URL.
/// Hosts a single "Open Document…" button that drives
/// `.fileImporter` — the visionOS-native way to pick a `.md` file
/// from Files.app. Picking a file rebinds the WindowGroup's URL
/// binding so the *current* window flips from welcome to document,
/// rather than spawning a second window.
struct WelcomeScreen: View {
  @Binding var fileURL: URL?
  @Environment(RecentDocumentsModel.self) private var recents
  @State private var isFilePickerPresented = false

  var body: some View {
    VStack(spacing: 24) {
      Image("AppIconImage")
        .resizable()
        .scaledToFit()
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      Text("Galley")
        .font(.largeTitle.weight(.semibold))
      Text("Open a Markdown document to preview it.")
        .foregroundStyle(.secondary)
      Button {
        isFilePickerPresented = true
      } label: {
        Label("Open Document…", systemImage: "folder")
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)

      if !recents.urls.isEmpty {
        recentsList
      }
    }
    .frame(minWidth: 600, minHeight: 800)
    .padding(40)
    .fileImporter(
      isPresented: $isFilePickerPresented,
      allowedContentTypes: MarkdownFileTypes.allTypesAndPlainText,
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first
      else { return }
      // The picked URL is security-scoped. Start access here; the
      // model holds the access for the lifetime of the scene by
      // never releasing — visionOS file pickers grant the scope per
      // session.
      _ = url.startAccessingSecurityScopedResource()
      recents.record(url)
      // Rebind this window's URL slot. The parent view's `if let`
      // flips to `DocumentScreen` on the next layout pass — no
      // second window spawned.
      fileURL = url
    }
  }

  /// Compact "Recent" panel below the Open button. Re-resolving a
  /// bookmark here yields a fresh security-scoped URL; we bind that
  /// — not the stored one — into the window slot.
  @ViewBuilder
  private var recentsList: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Recent")
          .font(.headline)
        Spacer()
        Button("Clear", role: .destructive) {
          recents.clearAll()
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      ForEach(recents.urls.prefix(5), id: \.self) { url in
        Button {
          if let fresh = recents.resolveRecentURL(url) {
            fileURL = fresh
          }
        } label: {
          HStack {
            Image(systemName: "doc.text")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(url.lastPathComponent)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
              Text(url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
          Button("Remove from Recent", role: .destructive) {
            // recents.remove(url)
          }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: 480)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
  }
}
