import GalleyCoreKit
import SwiftUI

/// SwiftUI-side bridge for the per-template background color cache.
/// The cache itself lives on `Defaults.shared.templateBackgroundColors`
/// (string-keyed by `Template.persistentID`, hex-encoded as
/// `#RRGGBBAA`) so it persists across launches and is observable —
/// any view that reads `template.backgroundColor` is automatically
/// invalidated when `BackgroundColorBridge` writes a new entry.
///
/// Hex parsing/encoding and the luminance test live on the shared
/// `KosmosAppKit.SRGBColor` value type (`SRGBColor(hex:)` / `.hex`,
/// `.isLuminanceDark`); this file only bridges those to SwiftUI `Color`
/// and the platform window-chrome machinery below.
///
/// Platform split:
/// - **Portable (this file, top half)**: storage, the
///   `TemplateBackgroundState` enum, and `Template.backgroundState` /
///   `setBackgroundColor`. Depends only on SwiftUI `Color`, `SRGBColor`,
///   and `Defaults.shared.templateBackgroundColors` /
///   `lastTemplateBackgroundColor` (each target's `Defaults` must
///   provide those two keys).
/// - **macOS-only (bottom half, `#if os(macOS)`)**: the NSColor /
///   NSAppearance chrome machinery — `Color.userSystemWindowBackground`,
///   `ColorScheme.userSystem`.

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

  enum Stored: Codable {
    case windowBackground
    case color(SRGBColor)
  }

  private var stored: Stored? {
    switch self {
    case .unresolved: nil
    case .resolved(let color):
      if color == .userSystemWindowBackground {
        .windowBackground
      } else {
        color.srgb.map { .color($0) }
      }
    }
  }

  private init(stored: Stored?) {
    switch stored {
    case .windowBackground:
      self = .resolved(.userSystemWindowBackground)
    case .color(let color):
      self = .resolved(color.color)
    case nil:
      self = .unresolved
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(stored: try decoder.singleValueContainer().decode(Stored?.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(stored)
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

/// macOS-only window-chrome machinery for the per-template background
/// cache. The portable storage layer (`TemplateBackgroundState`, the
/// `Template.backgroundState` / `setBackgroundColor` extensions) lives
/// in the top half of this file; hex/luminance are on
/// `KosmosAppKit.SRGBColor`. This section provides the macOS-only
/// surface the shared layer references: `Color.userSystemWindowBackground`
/// and `ColorScheme.userSystem`.
