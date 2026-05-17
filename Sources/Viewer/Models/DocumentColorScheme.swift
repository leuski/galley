//
//  DocumentColorScheme.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import Foundation
import SwiftUI

/// User-controllable color scheme for a rendered document. visionOS
/// has no system-level light/dark preference, so we offer a fixed
/// two-value choice that drives WebKit's `prefers-color-scheme` media
/// query (via the scene's `preferredColorScheme`) and — when
/// `Defaults.tintWindowWithPageBackground` is on — the window glass
/// tint.
///
/// macOS adopts the user's system appearance directly; this enum is
/// not surfaced there. The type lives in shared code so
/// `PerFileState` carries a uniform Codable shape across platforms,
/// which lets the same on-disk plist round-trip cleanly through the
/// Server (macOS) suite.
enum DocumentColorScheme: String, Codable, CaseIterable, Identifiable,
                         Hashable, Sendable
{
  case light
  case dark

  var id: String { rawValue }

  /// User-facing name. Strings live in the per-target catalog so each
  /// shipped locale can translate independently.
  var displayName: LocalizedStringResource {
    switch self {
    case .light: "Light"
    case .dark:  "Dark"
    }
  }

  /// SwiftUI color scheme this preference maps to. Applied via
  /// `.preferredColorScheme` on the document scene.
  var colorScheme: ColorScheme {
    switch self {
    case .light: .light
    case .dark:  .dark
    }
  }
}
