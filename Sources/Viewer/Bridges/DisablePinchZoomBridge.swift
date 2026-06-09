//
//  DisablePinchZoomBridge.swift
//  Galley
//
//  Created by Anton Leuski on 6/8/26.
//

#if !os(macOS)
import Foundation
import KosmosAppKit

@MainActor
enum DisablePinchZoomBridge {
  private final class Helper {}
  public static let disablePinchZoomScript = Bundle(for: Helper.self)
    .requiredString(forResource: "disablePinchZoom", withExtension: "js")
}
#endif
