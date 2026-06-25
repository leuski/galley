import Foundation
import WebKit
import OSLog
import GalleyCoreKit

/// Receives `{ "y": <Double> }` messages from a debounced scroll
/// listener in the rendered preview, so the owning DocumentModel can
/// keep the latest scroll position observable and DocumentSceneContent can
/// mirror it to `@SceneStorage` for cross-launch state restoration.
///
/// The listener fires ~150 ms after the last scroll event rather than
/// on every frame; @SceneStorage only needs the eventual resting
/// position, and per-frame updates would churn observation.
@MainActor
final class ScrollBridge: JavaScriptBridge {
  /// JS handler name. Script calls
  /// `window.webkit.messageHandlers.scroll.postMessage({ y: ... })`.
  static let messageName = "scroll"

  /// Debounced scroll listener. Source lives in
  /// `Resources/Scripts/scrollListener.js`; the message name is
  /// hardcoded there and must match `messageName` here.
  static let userScript = scriptFromResource(name: "scrollListener")

  /// Set by the owning DocumentModel; receives the latest position.
  var currentScrollY: Double = 0

  func handle(value msg: Value) {
    currentScrollY = msg.y
  }

  struct Value: Decodable { let y: Double }
}
