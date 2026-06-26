import Foundation
import GalleyCoreKit

/// Quick Look's view onto the shared `net.leuski.galley` defaults
/// suite. We don't have our own bundle id matching that suite, so
/// `UserDefaults(suiteName:)` returns a real, distinct domain here —
/// the same domain the Server writes to and the Viewer reads. QL
/// holds `temporary-exception.shared-preference.read-only` for this
/// suite (see `Quicklook.entitlements`), which is enough for the
/// read.
///
/// QL reads two keys: `serverHTTPPort` (composing the preview URL via
/// `serverEndpointURL`, falling back to in-process rendering when the
/// Server isn't running) and `template` (the user's selected template
/// id, so the in-process fallback honors it instead of always using the
/// bundled default).
///
/// The `@ObservableDefaults` macro requires a string literal for
/// `suiteName`, so we can't route through `GalleyConstants.suiteName`
/// here — keep this in sync with that constant if it ever changes.
@ObservableDefaults(
  suiteName: "net.leuski.galley",
  limitToInstance: false)
final class Defaults: GalleyDefaults, HTTPServerDefaults, GalleyRenderDefaults {
  var serverHTTPPort: UInt16 = 0
  var renderer: Processor.PersistentRepresentation?
  var template: Template.PersistentRepresentation?

  @MainActor static let shared = Defaults()
}
