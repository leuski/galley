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
extension Template {
  /// The page background color most recently reported by the
  /// `BackgroundColorBridge` for *this* template, or `nil` if the
  /// template has never been rendered (cache miss → DocumentView
  /// falls back to the system default chrome).
  @MainActor var backgroundColor: Color? {
    Defaults.shared.templateBackgroundColors[persistentID]
      .flatMap(Color.init(galleyHex:))
  }

  /// Persist `color` against this template's id so subsequent tabs
  /// using the same template seed correctly without flashing.
  /// Called by the bridge handler in `DocumentModel.wireBridges`.
  @MainActor func setBackgroundColor(_ color: Color) {
    guard let hex = color.galleyHex else { return }
    Defaults.shared.templateBackgroundColors[persistentID] = hex
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
}
