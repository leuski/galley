//
//  DocumentModel+Configuration.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import GalleyCoreKit
import SwiftUI
import WebKit

extension DocumentModel {
  /// Build the `WebPage.Configuration`: register every script-message
  /// handler, inject the user scripts each bridge needs, and wire the
  /// custom URL scheme that resolves template-bundled assets through
  /// `templateBox`. Static so it can run before `self` is fully
  /// initialized; pure plumbing — no closures capture the model.
  static func makeConfiguration(
    editorBridge: EditorBridge,
    linkBridge: LinkBridge,
    scrollBridge: ScrollBridge,
    tocBridge: TOCBridge,
    statsBridge: StatsBridge,
    backgroundBridge: BackgroundColorBridge,
    templateBox: TemplateBox
  ) -> WebPage.Configuration {
    var configuration = WebPage.Configuration()
    let controller = configuration.userContentController
    controller.add(editorBridge, name: EditorBridge.messageName)
    controller.add(linkBridge, name: LinkBridge.messageName)
    controller.add(scrollBridge, name: ScrollBridge.messageName)
    controller.add(tocBridge, name: TOCBridge.messageName)
    controller.add(statsBridge, name: StatsBridge.messageName)
    controller.add(
      backgroundBridge, name: BackgroundColorBridge.messageName)
    // One script handles both cmd-click → editor and plain click →
    // in-window nav, so we don't depend on capture-phase ordering
    // between two listeners — which appears to drop the editor
    // listener after the first navigation in macOS 26 WebPage.
    controller.addUserScript(WKUserScript(
      source: EditorBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Debounced scroll listener — feeds `currentScrollY` so
    // ContentView can persist the resting position via `@SceneStorage`.
    controller.addUserScript(WKUserScript(
      source: ScrollBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Heading extraction. Runs once per load, assigns synthetic ids
    // to headings that lack one, and posts the list back. Renderer-
    // agnostic — every Markdown processor we ship outputs `<h1>…<h6>`.
    controller.addUserScript(WKUserScript(
      source: TOCBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Word / character / heading counts for the optional status bar.
    // Reads `body.innerText`, so CSS-hidden chrome (template anchors,
    // copy-button glyphs) is excluded from the totals.
    controller.addUserScript(WKUserScript(
      source: StatsBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Computed background-color reader. Runs after layout so the
    // host can paint a matching tint behind translucent chrome.
    controller.addUserScript(WKUserScript(
      source: BackgroundColorBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Find-text controller. The style script runs at document-start
    // so the highlight CSS is in place before any match is wrapped;
    // the controller script runs at document-end so `document.body`
    // exists when `window.galleyFind` is wired up.
    controller.addUserScript(WKUserScript(
      source: FindBridge.styleScript,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true))
    controller.addUserScript(WKUserScript(
      source: FindBridge.userScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true))
    // Custom URL scheme so template-bundled assets (CSS, fonts,
    // images) resolve from disk through the SwiftUI WebView. Reads
    // the active template at request time via `templateBox`, kept
    // current by `renderCurrent` on every render.
    let handler = PreviewSchemeHandler(
      templateProvider: { templateBox.template ?? .default })
    configuration.urlSchemeHandlers[PreviewSchemeHandler.scheme] = handler
    return configuration
  }
}
