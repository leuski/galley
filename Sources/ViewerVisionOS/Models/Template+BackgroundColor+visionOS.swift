#if !os(macOS)
import GalleyCoreKit
import SwiftUI
import UIKit

/// visionOS / iOS counterpart of the macOS-only color machinery in
/// `Sources/Viewer/Models/Template+BackgroundColor+macOS.swift`.
/// The portable storage layer lives in
/// `Sources/ViewerShared/Models/Template+BackgroundColor.swift` and
/// references the surface declared here:
/// `Color.galleyHex`, `Color.isLuminanceDark`,
/// `Color.userSystemWindowBackground`, `ColorScheme.userSystem`.

extension ColorScheme {
  /// The user's system-wide preferred color scheme, ignoring any
  /// scene-level `preferredColorScheme` we've applied for chrome.
  /// On visionOS the trait collection tracks the user's preference;
  /// callers read this static accessor so the chrome can re-derive
  /// the scheme without threading the environment through.
  @MainActor static var userSystem: ColorScheme {
    UITraitCollection.current.userInterfaceStyle == .dark
      ? .dark : .light
  }
}

extension Color {
  /// `"#RRGGBBAA"` representation of this color through `UIColor` in
  /// sRGB. `nil` when the color can't be reduced to numeric
  /// components.
  var galleyHex: String? {
    let resolved = UIColor(self)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard resolved.getRed(
      &red, green: &green, blue: &blue, alpha: &alpha)
    else { return nil }
    let redByte = Int((red * 255).rounded())
    let greenByte = Int((green * 255).rounded())
    let blueByte = Int((blue * 255).rounded())
    let alphaByte = Int((alpha * 255).rounded())
    return String(
      format: "#%02X%02X%02X%02X",
      redByte, greenByte, blueByte, alphaByte)
  }

  /// Whether the color is dark enough that system-default text would
  /// disappear against it. ITU-R BT.601 luma weights, sRGB resolved
  /// via `UIColor`. Falls back to `false` when conversion fails.
  var isLuminanceDark: Bool {
    let resolved = UIColor(self)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard resolved.getRed(
      &red, green: &green, blue: &blue, alpha: &alpha)
    else { return false }
    let luma = 0.299 * red + 0.587 * green + 0.114 * blue
    return luma < 0.5
  }

  /// Deferred dynamic system window background. Resolves at draw
  /// time through the user's current trait collection, so toggling
  /// system appearance live updates the visible color without cache
  /// invalidation. Mirrors the macOS `NSColor(name:)` provider
  /// pattern — the `Color` returned here is `==` only to itself, so
  /// the `TemplateBackgroundState` Codable boundary can use one
  /// equality comparison to separate "use the deferred sentinel"
  /// from every hex-decoded opaque color.
  static let userSystemWindowBackground = Color(
    uiColor: UIColor(dynamicProvider: { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.systemBackground.resolvedColor(
          with: UITraitCollection(userInterfaceStyle: .dark))
        : UIColor.systemBackground.resolvedColor(
          with: UITraitCollection(userInterfaceStyle: .light))
    }))
}
#endif
