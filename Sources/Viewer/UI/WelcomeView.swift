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
  @Environment(AppModel.self) var appModel
  private var recents: RecentDocumentsModel { appModel.recents }
  @State private var isOpen: Bool = false

  var body: some View {
    HStack(spacing: 40) {
      VStack(spacing: 8) {
        Image("AppIconImage")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 256)
        Text("Galley")
          .font(.largeTitle.bold())

        Action.open(isPresented: $isOpen, appModel: appModel).menuItem()
          .modifier(OpenFileModifier(isPresented: $isOpen, appModel: appModel))
          .buttonStyle(.borderedProminent)
      }

      if !recents.urls.isEmpty {
        recentsList
          .frame(maxWidth: 600, maxHeight: .infinity)
      }
    }
    .padding(40)
    .frame(
      minWidth: 900, maxWidth: .infinity,
      minHeight: 700, maxHeight: .infinity)
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
  }
}
