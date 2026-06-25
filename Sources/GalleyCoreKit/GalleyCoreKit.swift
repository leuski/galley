// GalleyCoreKit — shared core for both the Galley Server
// (menu-bar) and the Galley document viewer. Houses rendering,
// templates, document watching, and helpers that work in any preview
// context. No HTTP server here — see GalleyServerKit for that.
import Foundation
@_exported import ObservableDefaults
@_exported import KosmosAppKit

private final class Helper: NSObject {}

public extension Bundle {
  static let galleyCoreKit = Bundle(for: Helper.self)
}
