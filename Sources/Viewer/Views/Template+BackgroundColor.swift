import AppKit
import GalleyCoreKit
import SwiftUI

/// SwiftUI-side bridge for the per-template background color cache.
/// The cache itself lives on `Defaults.shared.templateBackgroundColors`
/// (string-keyed by `Template.persistentID`, hex-encoded as
/// `#RRGGBBAA`) so it persists across launches and is observable —
/// any view that reads `template.backgroundColor` is automatically
/// invalidated when `BackgroundColorBridge` writes a new entry. The
/// extension lives in the Viewer module rather than `GalleyCoreKit`
/// so the kit stays SwiftUI-free.
/// Sentinel stored in `Defaults.shared.templateBackgroundColors`
/// when a template has been rendered and explicitly declares no
/// opaque page background. Distinct from "never rendered" (no
/// dictionary entry at all) so a stale cached color from an
/// earlier render with different CSS gets overwritten when the
/// user edits the template to remove its bg.
private let templateBackgroundNoneSentinel = ""

/// Resolution state for a template's page background. Encodes the
/// three states the chrome's display logic actually needs to
/// distinguish:
///
/// - `.unresolved` — the template has never been rendered (or this
///   session can't tell). Caller should fall back to the global
///   last-seen color, or the system window bg if even that is
///   unknown.
/// - `.resolved(let color)` — the template was rendered and
///   reported `color` as its opaque page bg. Caller paints `color`
///   directly.
/// - `.resolvedNone` — the template was rendered and reported no
///   opaque bg. Caller paints the system window bg, just like the
///   `unresolved` ↔ no-last-seen case but skipping the last-seen
///   step (the template *positively* has no bg, not "we don't
///   know yet").
public enum TemplateBackgroundState {
  case unresolved
  case resolved(Color)
  case resolvedNone
}

extension Template {
  /// The page background's resolution state for this template,
  /// driven by `Defaults.shared.templateBackgroundColors`. Read by
  /// `DocumentModel.pageBackgroundColor` to choose between the
  /// template's own color, the global last-seen fallback, and the
  /// system window bg.
  @MainActor var backgroundState: TemplateBackgroundState {
    guard let stored = Defaults.shared
      .templateBackgroundColors[persistentID]
    else { return .unresolved }
    if stored == templateBackgroundNoneSentinel {
      return .resolvedNone
    }
    if let color = Color(galleyHex: stored) {
      return .resolved(color)
    }
    // Corrupt entry — treat as if we'd never seen it.
    return .unresolved
  }

  /// Persist the bridge's latest report against this template's id.
  /// Always writes — `color: nil` records the sentinel so a stale
  /// hex entry from an earlier render is invalidated. Called by the
  /// bridge handler in `DocumentModel.wireBridges`. When `color`
  /// is non-nil the global `lastTemplateBackgroundColor` is also
  /// updated so brand-new templates seed correctly on next open.
  @MainActor func setBackgroundColor(_ color: Color?) {
    let value: String
    if let color, let hex = color.galleyHex {
      value = hex
      Defaults.shared.lastTemplateBackgroundColor = hex
    } else {
      value = templateBackgroundNoneSentinel
    }
    Defaults.shared.templateBackgroundColors[persistentID] = value
  }
}

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
  /// Parse `"#RRGGBB"` or `"#RRGGBBAA"` into a `Color`. Strict —
  /// returns `nil` for any other shape so a corrupt cache entry
  /// can't poison the chrome silently.
  init?(galleyHex hex: String) {
    var stripped = hex
    if stripped.hasPrefix("#") {
      stripped = String(stripped.dropFirst())
    }
    guard stripped.count == 6 || stripped.count == 8,
          let value = UInt64(stripped, radix: 16) else {
      return nil
    }
    let red, green, blue, alpha: Double
    if stripped.count == 8 {
      red = Double((value >> 24) & 0xff) / 255
      green = Double((value >> 16) & 0xff) / 255
      blue = Double((value >> 8) & 0xff) / 255
      alpha = Double(value & 0xff) / 255
    } else {
      red = Double((value >> 16) & 0xff) / 255
      green = Double((value >> 8) & 0xff) / 255
      blue = Double(value & 0xff) / 255
      alpha = 1
    }
    self = Color(
      .sRGB, red: red, green: green, blue: blue, opacity: alpha)
  }

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
  @MainActor static var userSystemWindowBackground: Color {
    var resolved: NSColor = .windowBackgroundColor
    NSApp.effectiveAppearance
      .performAsCurrentDrawingAppearance {
        if let srgb = NSColor.windowBackgroundColor
          .usingColorSpace(.sRGB) {
          resolved = srgb
        }
      }
    return Color(nsColor: resolved)
  }
}
