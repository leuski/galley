//
//  VisionDocumentScene.swift
//  Galley
//
//  Created by Anton Leuski on 5/31/26.
//

#if os(visionOS)
import SwiftUI
import GalleyCoreKit

struct VisionDocumentScene: Scene {
  static let id = "document"
  static let events = Set(["file:", "\(OpenDocumentActivity.scheme):"])

  var body: some Scene {
    WindowGroup(id: Self.id, for: DocumentTarget.self) { $target in
      VisionContentView(target: $target)
    }
    .handlesExternalEvents(matching: Self.events)
    .windowResizability(.contentSize)
  }
}

#endif
