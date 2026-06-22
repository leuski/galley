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

  var body: some View {
    HStack(spacing: 24) {
      VStack(spacing: 8) {
        Image(systemName: "doc.richtext")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        Text("Galley")
          .font(.largeTitle.bold())

        Action.open().menuItem()
          .buttonStyle(.borderedProminent)
      }
      .padding(40)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if !recents.urls.isEmpty {
        recentsList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var recentsList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recent Documents")
        .font(.headline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
      VStack(spacing: 0) {
        ForEach(recents.urls.prefix(8), id: \.self) { url in
          Action.openRecent(url, recents: recents)
            .listRow()
        }
      }
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: Action.listCornerRadius)
          .fill(.background))
    }
    .frame(maxWidth: 560, alignment: .leading)
  }
}
