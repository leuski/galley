#if os(macOS)
import GalleyCoreKit
import SwiftUI

/// Hosts document-URL receipt for one window. Replaces
/// `BootstrapDispatchModifier` + `WindowDispatcher`: SwiftUI selects the
/// window (`handlesExternalEvents`), the handler just records + opens.
///
/// Routing model (WindowProbe FINDINGS §4–§6):
///   - every window `allowing: ["*"]` so a brand-new document URL lands
///     on the key window (the tie-breaker);
///   - a document window additionally `preferring:` its own URL tokens,
///     so a repeat-open routes back to it (dedup) regardless of focus.
///
/// Settings and Help are **not** handled here — they have their own
/// schemes (`galley-settings://`, `galley-help://`) claimed by the
/// Settings / Help scenes via `handlesExternalEvents`, so SwiftUI routes
/// them straight to those singleton scenes. A document window therefore
/// only ever sees `galley://<path>` and `file://` document URLs.
struct InboundURLHandler: ViewModifier {
  let enabled: Bool
  /// Tokens this window prefers for dedup (empty for the bootstrap
  /// window).
  let preferring: Set<String>
  /// What to do with a document URL that reached this window.
  let onDocument: (DocumentTarget) -> Void

  func body(content: Content) -> some View {
    if enabled {
      content
        .handlesExternalEvents(
          preferring: preferring, allowing: DocumentScene.events)
        .onOpenURL { route($0) }
    } else {
      content
    }
  }

  private func route(_ url: URL) {
    guard let document = GalleyViewerRequestActivity(from: url) else {
      return
    }
    onDocument(document.target)
  }
}

extension View {
  /// Attach document-URL receipt to a window's content.
  func handlesInboundURLs(
    enabled: Bool = true,
    preferring: Set<String> = [],
    onDocument: @escaping (DocumentTarget) -> Void
  ) -> some View {
    modifier(InboundURLHandler(
      enabled: enabled, preferring: preferring, onDocument: onDocument))
  }
}
#endif
