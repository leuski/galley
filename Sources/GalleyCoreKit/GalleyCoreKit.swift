// GalleyCoreKit — shared core for both the Markdown Preview Server
// (menu-bar) and the Markdown Eye document viewer. Houses rendering,
// templates, document watching, and helpers that work in any preview
// context. No HTTP server here — see GalleyServerKit for that.
import Foundation

private final class Helper: NSObject {}

public extension Bundle {
  static let galleyCoreKit = Bundle(for: Helper.self)
}
