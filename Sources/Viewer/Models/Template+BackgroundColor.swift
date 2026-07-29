import GalleyCoreKit
import SwiftUI

/// SwiftUI-side bridge for the per-template background color cache.
/// The cache itself lives on `Defaults.shared.templateBackgroundColors`
/// (string-keyed by `Template.persistentID`, hex-encoded as
/// `#RRGGBBAA`) so it persists across launches and is observable —
/// any view that reads `template.backgroundColor` is automatically
/// invalidated when `BackgroundColorBridge` writes a new entry.
///
/// Platform split:
/// - **Portable (this file)**: storage, the `TemplateBackgroundState`
///   enum, `Template.backgroundState` / `setBackgroundColor`, and
///   the hex string `Color(galleyHex:)` parser. Depends only on
///   SwiftUI `Color` and `Defaults.shared.templateBackgroundColors`
///   / `lastTemplateBackgroundColor` (each target's `Defaults` must
///   provide those two keys).
/// - **macOS-only (`Template+BackgroundColor+macOS.swift`)**: the
///   NSColor / NSAppearance machinery — `Color.galleyHex` getter,
///   `Color.isLuminanceDark`, `Color.userSystemWindowBackground`,
///   `ColorScheme.userSystem`.
/// - **visionOS-only (`Sources/ViewerVisionOS/Models/`)**: UIColor
///   equivalents of the same surface.

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
public enum TemplateBackgroundState: Codable, Equatable {
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
      } else if let color = SRGBColor(hex: string)?.color {
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
      // wrapping a named dynamic NSColor / UIColor) is `==` only to
      // itself, never to a hex-decoded literal that *happens to*
      // render the same RGB. That property lets a single comparison
      // separate "the deferred sentinel" from every real opaque
      // color.
      if color == .userSystemWindowBackground {
        templateBackgroundNoneSentinel
      } else {
        color.srgb?.hex
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
    Defaults.shared.templateBackgroundColors[id.rawValue] ?? .unresolved
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
    Defaults.shared.templateBackgroundColors[id.rawValue] = value
  }
}

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
#if os(macOS)
    NSApp.effectiveAppearance
      .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ? .dark : .light
#else
    UITraitCollection.current.userInterfaceStyle == .dark
    ? .dark : .light
#endif
  }
}

extension Color {
#if os(macOS)
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
#else
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
#endif
}
