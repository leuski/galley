//
//  DocumentModel+Configuration.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import GalleyCoreKit
#if os(visionOS)
import KosmosHTTPTunnel
#endif
import SwiftUI
import WebKit

extension DocumentModel {
  /// Build the `WebPage.Configuration`: register every script-message
  /// handler, inject the user scripts each bridge needs, and wire the
  /// custom URL scheme that resolves template-bundled assets through
  /// `templateProvider`. Static so it can run before `self` is fully
  /// initialized; pure plumbing — no closures capture the model.
  static func makeConfiguration(
    editorBridge: EditorBridge,
    linkBridge: LinkBridge,
    scrollBridge: ScrollBridge,
    tocBridge: TOCBridge,
    statsBridge: StatsBridge,
    backgroundBridge: BackgroundColorBridge,
    templateProvider: @escaping @MainActor @Sendable () -> Template,
    kosmosTunnel: KosmosTunnelClientRef? = nil
  ) -> WebPage.Configuration {
    var configuration = WebPage.Configuration()
    configuration.defaultNavigationPreferences.preferredContentMode = .desktop
    let controller = configuration.userContentController
    controller.add(
      // One script handles both cmd-click → editor and plain click →
      // in-window nav, so we don't depend on capture-phase ordering
      // between two listeners — which appears to drop the editor
      // listener after the first navigation in macOS 26 WebPage.
      editorBridge,
      // Debounced scroll listener — feeds `currentScrollY` so
      // ContentView can persist the resting position via `@SceneStorage`.
      scrollBridge,
      // Heading extraction. Runs once per load, assigns synthetic ids
      // to headings that lack one, and posts the list back. Renderer-
      // agnostic — every Markdown processor we ship outputs `<h1>…<h6>`.
      tocBridge,
      // Word / character / heading counts for the optional status bar.
      // Reads `body.innerText`, so CSS-hidden chrome (template anchors,
      // copy-button glyphs) is excluded from the totals.
      statsBridge,
      // Computed background-color reader. Runs after layout so the
      // host can paint a matching tint behind translucent chrome.
      backgroundBridge
    )
    controller.add(linkBridge, name: LinkBridge.messageName)
    // Find-text controller. The style script runs at document-start
    // so the highlight CSS is in place before any match is wrapped;
    // the controller script runs at document-end so `document.body`
    // exists when `window.galleyFind` is wired up.
    controller.addUserScript(FindBridge.styleScript)
    controller.addUserScript(FindBridge.userScript)
#if !os(macOS)
    // visionOS pinches the WebView's content like an iOS WKWebView
    // unless the document opts out via viewport meta. Templates we
    // ship don't all declare one, and even when they do the page
    // would still scale on touch. Force a non-scalable viewport so
    // pinch gestures inside the WebView don't fight the app's own
    // zoom action.
    controller.addUserScript(disablePinchZoomScript)
#endif
    // Custom URL scheme so template-bundled assets (CSS, fonts,
    // images) resolve from disk through the SwiftUI WebView. The
    // provider closure reads the live template selection on every
    // asset request, so a mid-session template switch is reflected
    // in the next `/template/<id>/<file>` lookup without any
    // explicit invalidation.
    let handler = PreviewSchemeHandler(templateProvider: templateProvider)
    configuration.urlSchemeHandlers[PreviewSchemeHandler.scheme] = handler

#if os(visionOS)
    // AVP renders Mac-hosted documents by tunneling each WebKit fetch
    // through Kosmos via the `galley://` scheme. The handler holds a
    // reference to the shared `Client` owned by
    // `VisionKosmosService`.
    if let kosmosTunnel = kosmosTunnel?.client {
      let tunnelHandler = KosmosTunnelSchemeHandler(tunnel: kosmosTunnel)
      configuration.urlSchemeHandlers[KosmosTunnelSchemeHandler.scheme]
        = tunnelHandler
    }
#endif

    return configuration
  }
}

/// Type-erased holder so the (visionOS-only) tunnel-client type
/// doesn't leak into the shared `makeConfiguration` signature on
/// macOS. The macOS slice ignores the parameter; visionOS reads the
/// inner client and registers the scheme handler.
struct KosmosTunnelClientRef {
#if os(visionOS)
  let client: Client
#else
  /// macOS keeps the type around for source compatibility but
  /// can't construct it.
  var client: Never? { nil }
#endif
}

#if !os(macOS)
/// Forces a non-scalable viewport meta tag so the WebView ignores
/// touch pinch gestures on visionOS. Replaces any existing tag
/// rather than appending, so a template-provided viewport doesn't
/// keep its `user-scalable=yes` (the default).
private let disablePinchZoomScript = """
(function() {
  var head = document.head || document.getElementsByTagName('head')[0];
  if (!head) { return; }
  var meta = head.querySelector('meta[name="viewport"]');
  if (!meta) {
    meta = document.createElement('meta');
    meta.name = 'viewport';
    head.appendChild(meta);
  }
  meta.setAttribute(
    'content',
    'width=device-width, initial-scale=1.0, ' +
    'maximum-scale=1.0, minimum-scale=1.0, user-scalable=no');
})();
"""
#endif
