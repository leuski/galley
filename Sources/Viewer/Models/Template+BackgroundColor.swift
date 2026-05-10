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

/// Resolution state for a template's page background. Two cases:
///
/// - `.unresolved` — the template has never been rendered (or the
///   cache entry is missing). Caller falls back to the global
///   last-seen state, or the system window bg.
/// - `.resolved(let color)` — the template was rendered and
///   reported `color` as its page bg. Two subtly different things
///   collapse here:
///   * The template painted an explicit opaque color → `color` is
///     the corresponding sRGB-pinned `Color`.
///   * The template declared no opaque bg → `color` is the
///     deferred dynamic `Color.userSystemWindowBackground`, which
///     re-resolves to the user's current system bg on every draw.
///   The `Codable` boundary distinguishes the two via `Color`
///   equality with the static `userSystemWindowBackground`
///   reference: that one comparison detects "use the deferred
///   sentinel" and round-trips as the empty-string sentinel; any
///   other color round-trips as a hex literal.
public enum TemplateBackgroundState: Codable {
  case unresolved
  case resolved(Color)

  /// The color the chrome should paint behind this state. `Color`
  /// is always real; callers don't have to thread fallbacks. The
  /// `.unresolved` branch defers to `Defaults.shared
  /// .lastTemplateBackgroundColor` but resolves it manually rather
  /// than calling `.color` recursively, so a corrupt or hand-
  /// edited last-seen entry can't trigger a stack overflow.
  @MainActor
  public var color: Color {
    switch self {
    case .resolved(let color):
      return color
    case .unresolved:
      switch Defaults.shared.lastTemplateBackgroundColor {
      case .resolved(let color):
        return color
      case .unresolved:
        return .userSystemWindowBackground
      }
    }
  }

  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String?.self) {
    case .none:
      self = .unresolved
    case .some(let string):
      if string == templateBackgroundNoneSentinel {
        self = .resolved(.userSystemWindowBackground)
      } else if let color = Color(galleyHex: string) {
        self = .resolved(color)
      } else {
        self = .unresolved
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    let value: String? = switch self {
    case .unresolved: nil
    case .resolved(let color):
      // `Color` equality compares the underlying storage, not the
      // pixels rendered at draw time — so `Color
      // .userSystemWindowBackground` (a single static reference
      // wrapping a named dynamic NSColor) is `==` only to itself,
      // never to a hex-decoded literal that *happens to* render
      // the same RGB. That property lets a single comparison
      // separate "the deferred sentinel" from every real opaque
      // color.
      if color == .userSystemWindowBackground {
        templateBackgroundNoneSentinel
      } else {
        color.galleyHex
      }
    }
    try container.encode(value)
  }
}

extension Template {
  /// The page background's resolution state for this template,
  /// driven by `Defaults.shared.templateBackgroundColors`. Read by
  /// `DocumentModel.pageBackgroundColor` to choose between the
  /// template's own color, the global last-seen fallback, and the
  /// system window bg.
  @MainActor var backgroundState: TemplateBackgroundState {
    Defaults.shared.templateBackgroundColors[persistentID] ?? .unresolved
  }

  /// Persist the bridge's latest report against this template's id.
  /// Always writes — `color: nil` records the sentinel so a stale
  /// hex entry from an earlier render is invalidated. Called by the
  /// bridge handler in `DocumentModel.wireBridges`. When `color`
  /// is non-nil the global `lastTemplateBackgroundColor` is also
  /// updated so brand-new templates seed correctly on next open.
  @MainActor func setBackgroundColor(_ color: Color?) {
    let value: TemplateBackgroundState = .resolved(
      color ?? .userSystemWindowBackground)
    Defaults.shared.lastTemplateBackgroundColor = value
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
