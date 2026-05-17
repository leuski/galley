import Foundation
@_exported import ObservableDefaults
import GalleyCoreKit

/// visionOS counterpart of the macOS Viewer's `Defaults`.
///
/// Only the subset of keys read by `Sources/ViewerShared/` is here:
///
/// - `renderer` / `template` — persisted choice IDs the
///   `ProcessorChoice` / `TemplateChoice` round-trip through.
/// - `enablePerDocumentOverrides` — read by
///   `DocumentModel.resolvedRenderer` / `resolvedTemplate`. Stays
///   `false` on visionOS for v1 (no per-document overrides UI).
/// - `templateBackgroundColors` /
///   `lastTemplateBackgroundColor` — read by
///   `Template.backgroundState` and
///   `TemplateBackgroundState.color`. Driven by
///   `BackgroundColorBridge` after each render.
///
/// macOS-only keys (`editor`, `openBehavior`, `transparentToolbar`,
/// `showsStatusBar`, `readingWordsPerMinute`, etc.) are intentionally
/// omitted — visionOS has no external-editor concept, no native window
/// tabbing, no toolbar chrome reading the bg-luminance flip, and no
/// optional bottom status bar. Add them only if a visionOS feature
/// needs them.
///
/// `perFileStateStore` is included because shared code references it
/// via `BindPlan.decide(perFileState:)`; visionOS hosts pass
/// `{ Defaults.shared.perFileStateStore[$0] }` the same way macOS
/// does.
@ObservableDefaults(limitToInstance: false)
final class Defaults: GalleyRenderDefaults {
  @DefaultsKey var renderer: String?
  @DefaultsKey var template: String?
  @DefaultsKey var enablePerDocumentOverrides: Bool = false
  @DefaultsKey var perFileStateStore: [String: PerFileState] = [:]
  @DefaultsKey var templateBackgroundColors:
    [String: TemplateBackgroundState] = [:]
  @DefaultsKey var lastTemplateBackgroundColor: TemplateBackgroundState
    = .unresolved
  /// Whether the bottom `StatusBar` HUD (word count, reading time,
  /// heading count) is visible in document windows. Toggled via
  /// `Action.toggleStatusBar`.
  @DefaultsKey var showsStatusBar: Bool = false
  /// Words-per-minute used to estimate reading time in the status
  /// bar. 200 is the rough middle of the literature on prose reading
  /// speed.
  @DefaultsKey var readingWordsPerMinute: Int = 200

  @MainActor static let shared = Defaults()

  /// Synchronize the `@ObservableDefaults` macro's per-property cache
  /// with the actual on-disk values. Must be called once at app boot,
  /// BEFORE any SwiftUI layout pass. See the macOS `Defaults.warmCache()`
  /// doc comment for the WebKit-triggered reentrancy this prevents.
  @MainActor static func warmCache() {
    _ = Defaults.shared
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: UserDefaults.standard)
  }
}
