import Foundation
import GalleyCoreKit
import WebKit

/// Find-text user scripts. Installs a `window.galleyFind` controller
/// that walks text nodes, wraps every match in a `<mark>` element, and
/// exposes `search` / `next` / `prev` / `clear` so Swift can drive
/// in-page find via `page.callJavaScript`.
///
/// Sources live in `Resources/Scripts/findStyle.js` and
/// `Resources/Scripts/findController.js` — see the comments at the
/// top of each. Highlighting is DOM-mutating so we get a Safari-style
/// "highlight every match, scroll to current" experience that
/// `window.find()` can't provide. The controller script also runs on
/// every load, re-installing `window.galleyFind` against the freshly-
/// built DOM.
@MainActor
enum FindBridge {
  /// Document-start CSS so highlight styles are present before the
  /// renderer's body markup is parsed; avoids a flash of unstyled
  /// `<mark>` on the very first match after a reload.
  static let styleScript: String = Bundle.main.requiredString(
    forResource: "findStyle", withExtension: "js")

  /// Document-end controller. Re-creates `window.galleyFind` on every
  /// load so a freshly-rendered DOM picks up a clean state.
  static let userScript: String = Bundle.main.requiredString(
    forResource: "findController", withExtension: "js")
}
