import Foundation
import WebKit
import OSLog
import GalleyCoreKit
import KosmosAppKit

/// Receives `{ "y": <Double> }` messages from a debounced scroll
/// listener in the rendered preview, so the owning DocumentModel can
/// keep the latest scroll position observable and ContentView can
/// mirror it to `@SceneStorage` for cross-launch state restoration.
///
/// The listener fires ~150 ms after the last scroll event rather than
/// on every frame; @SceneStorage only needs the eventual resting
/// position, and per-frame updates would churn observation.
@MainActor
final class ScrollBridge: NSObject, JavaScriptBridge {
  /// JS handler name. Script calls
  /// `window.webkit.messageHandlers.scroll.postMessage({ y: ... })`.
  static let messageName = "scroll"

  /// Debounced scroll listener. Source lives in
  /// `Resources/Scripts/scrollListener.js`; the message name is
  /// hardcoded there and must match `messageName` here.
  static let userScript: String = Bundle(for: ScrollBridge.self)
    .requiredString(forResource: "scrollListener", withExtension: "js")

  /// Set by the owning DocumentModel; receives the latest position.
  var onScroll: ((Double) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "ScrollBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let msg = try? message.decodedBody(Message.self) else {
      logMalformedMessage(message.body)
      return
    }
    onScroll?(msg.y)
  }

  private struct Message: Decodable { let y: Double }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed scroll message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
