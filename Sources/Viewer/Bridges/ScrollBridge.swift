import Foundation
import WebKit
import OSLog
import GalleyCoreKit

/// Receives `{ "y": <Double> }` messages from a debounced scroll
/// listener in the rendered preview, so the owning DocumentModel can
/// keep the latest scroll position observable and ContentView can
/// mirror it to `@SceneStorage` for cross-launch state restoration.
///
/// The listener fires ~150 ms after the last scroll event rather than
/// on every frame; @SceneStorage only needs the eventual resting
/// position, and per-frame updates would churn observation.
@MainActor
final class ScrollBridge: NSObject, WKScriptMessageHandler {
  /// JS handler name. Script calls
  /// `window.webkit.messageHandlers.scroll.postMessage({ y: ... })`.
  static let messageName = "scroll"

  /// Debounced scroll listener. Source lives in
  /// `Resources/Scripts/scrollListener.js`; the message name is
  /// hardcoded there and must match `messageName` here.
  static let userScript: String = Bundle.main.requiredString(
    forResource: "scrollListener", withExtension: "js")

  /// Set by the owning DocumentModel; receives the latest position.
  var onScroll: ((Double) -> Void)?

  private let logger = Logger(
    subsystem: bundleIdentifier,
    category: "ScrollBridge")

  func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    let value: Double?
    if let body = message.body as? [String: Any],
       let raw = body["y"]
    {
      if let number = raw as? Double {
        value = number
      } else if let number = raw as? NSNumber {
        value = number.doubleValue
      } else {
        value = nil
      }
    } else {
      value = nil
    }
    guard let y = value else {
      logMalformedMessage(message.body)
      return
    }
    onScroll?(y)
  }

  private func logMalformedMessage(_ body: Any) {
    logger.warning("""
      Ignoring malformed scroll message: \
      \(String(describing: body), privacy: .public)
      """)
  }
}
