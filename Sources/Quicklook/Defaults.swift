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
/// We only need `serverHTTPPort` — QL composes the preview URL via
/// `serverEndpointURL` from `GalleyNetworkDefaults` and falls back
/// to in-process rendering when the Server isn't running.
///
/// The `@ObservableDefaults` macro requires a string literal for
/// `suiteName`, so we can't route through `GalleyConstants.suiteName`
/// here — keep this in sync with that constant if it ever changes.
@ObservableDefaults(
  suiteName: "net.leuski.galley",
  limitToInstance: false)
final class Defaults: GalleyDefaults, HTTPServerDefaults {
  var serverHTTPPort: UInt16 = 0

  @MainActor static let shared = Defaults()
}
