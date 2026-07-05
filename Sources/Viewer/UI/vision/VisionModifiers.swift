//
//  Modifiers.swift
//  Galley
//
//  Created by Anton Leuski on 6/17/26.
//

#if os(visionOS)
import SwiftUI
import GalleyCoreKit

@MainActor
func handlePhaseChange(
  _ openWindow: OpenWindowAction, appModel: AppModel)
-> ((ScenePhase, ScenePhase) -> Void)
{
  { _, newPhase in
    // App-level (aggregate) phase. Drives Kosmos suspend/resume,
    // and tells the registry to suppress `onNeedEmpty` while the
    // whole app is on its way out — otherwise per-scene
    // `.background` transitions during app backgrounding would
    // each look like a fresh dismissal and try to spawn empties.
    appModel.didChangePhase(scenePhase: newPhase) {
      openWindow(id: DocumentScene.id)
    }
    switch newPhase {
    case .active, .inactive:
      appModel.kosmos.publishResume()
    case .background:
      appModel.kosmos.publishSuspend()
    @unknown default:
      break
    }
  }
}

#endif
