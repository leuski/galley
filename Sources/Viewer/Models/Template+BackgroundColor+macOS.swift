import AppKit
import GalleyCoreKit
import SwiftUI

/// macOS-only color machinery for the per-template background cache.
/// The portable storage layer (`TemplateBackgroundState`, the
/// `Template.backgroundState` / `setBackgroundColor` extensions, and
/// the hex parser `Color(galleyHex:)`) lives in
/// `Sources/ViewerShared/Models/Template+BackgroundColor.swift`.
/// This file provides the macOS half of the surface the shared layer
/// references: `Color.galleyHex`, `Color.isLuminanceDark`,
/// `Color.userSystemWindowBackground`, `ColorScheme.userSystem`.

extension ColorScheme {
  /// The user's system-wide preferred color scheme, ignoring any
  /// scene-level `preferredColorScheme` we've applied for chrome.
  /// Used to reset `NSWindow.appearance` (via `preferredColorScheme`
  /// on the scene) before re-rendering after a template change so
  /// WebKit's `prefers-color-scheme` media queries pick the user's
  /// preferred variant — not whichever variant was current under
  /// the previous template's bg-luminance-derived scheme.
  @MainActor static var userSystem: ColorScheme {
    NSApp.effectiveAppearance
      .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ? .dark : .light
  }
}

extension Color {
  /// `"#RRGGBBAA"` representation of this color through `NSColor` in
  /// sRGB. `nil` when the color can't be reduced to numeric
  /// components (catalog colors with no sRGB form, etc.).
  var galleyHex: String? {
    guard let resolved = NSColor(self).usingColorSpace(.sRGB) else {
      return nil
    }
    let red = Int((resolved.redComponent * 255).rounded())
    let green = Int((resolved.greenComponent * 255).rounded())
    let blue = Int((resolved.blueComponent * 255).rounded())
    let alpha = Int((resolved.alphaComponent * 255).rounded())
    return String(
      format: "#%02X%02X%02X%02X", red, green, blue, alpha)
  }

  /// Whether the color is dark enough that AppKit's default
  /// system-dark text would disappear against it. Resolves through
  /// `NSColor` in sRGB and applies ITU-R BT.601 luma weights. Falls
  /// back to `false` when the conversion can't be made.
  var isLuminanceDark: Bool {
    guard let resolved = NSColor(self).usingColorSpace(.sRGB) else {
      return false
    }
    let luma = 0.299 * resolved.redComponent
    + 0.587 * resolved.greenComponent
    + 0.114 * resolved.blueComponent
    return luma < 0.5
  }

  /// Backing dynamic `NSColor` for `userSystemWindowBackground`.
  /// Resolves at draw time through the user's *system-wide*
  /// preferred appearance — read directly from
  /// `AppleInterfaceStyle` instead of the appearance handed to the
  /// provider, which would reflect any scene-local
  /// `preferredColorScheme` override we've applied for chrome.
  ///
  /// Pinned to sRGB inside the appearance block so the returned
  /// `NSColor` is a concrete numeric value rather than another
  /// dynamic alias — `Color(nsColor:)` then captures it as a
  /// stable component but each draw still re-invokes the provider,
  /// so the visible color follows the user toggling system
  /// appearance live without any cache invalidation on our side.
  /// `NSColor.windowBackgroundColor` resolved through the *user's*
  /// system appearance, not the scene's local
  /// `preferredColorScheme`.
  ///
  /// We flip `preferredColorScheme` on the document scene based on
  /// the page bg luminance — that's correct for AppKit-rendered
  /// chrome text on top of a dark template. But it also makes
  /// `Color(nsColor: .windowBackgroundColor)` resolve through the
  /// flipped scheme, which is wrong for "fallback when no template
  /// color is cached yet" — that fallback should reflect what the
  /// user has set system-wide, not what we forced for a different
  /// reason. `NSApp.effectiveAppearance` still tracks the user's
  /// preference because `preferredColorScheme` is applied at the
  /// scene/window level, not the app level.
  static let userSystemWindowBackground = Color(
    nsColor: NSColor(name: "galley.userSystemWindowBackground") { _ in
      let isDark = UserDefaults.standard
        .string(forKey: "AppleInterfaceStyle") == "Dark"
      let appearance = NSAppearance(
        named: isDark ? .darkAqua : .aqua)
      ?? NSAppearance.currentDrawing()
      var resolved: NSColor = .windowBackgroundColor
      appearance.performAsCurrentDrawingAppearance {
        if let srgb = NSColor.windowBackgroundColor
          .usingColorSpace(.sRGB) {
          resolved = srgb
        }
      }
      return resolved
    })
}
