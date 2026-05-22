//
//  DocumentModel+Resolution.swift
//  Galley
//
//  Created by Anton Leuski on 5/16/26.
//

import GalleyCoreKit
import SwiftUI

extension DocumentModel {
  /// Resolve the renderer for the next render. When the per-document
  /// override flag is on, the window-local choice wins (falling back
  /// to the global selection if its pick is unavailable). Otherwise
  /// always use the global selection.
  func resolvedRenderer() -> any MarkdownRenderer {
    if Defaults.shared.enablePerDocumentOverrides == true,
       let renderer = processors.selected.value.renderer
    {
      return renderer
    }

    return appModel.processors.selected.value.renderer
    ?? SwiftMarkdownRenderer()
  }

  /// Static so the scheme-handler closure built in `init` (before
  /// `self` is fully initialized) can call this with captured
  /// reference-type properties instead of going through `self`.
  static func resolveTemplate(
    templates: SceneTemplateChoice,
    appModel: AppModel
  ) -> Template {
    if Defaults.shared.enablePerDocumentOverrides == true {
      return templates.selected.value
    }
    return appModel.templates.selected.value
  }

  func resolvedTemplate() -> Template {
    Self.resolveTemplate(templates: templates, appModel: appModel)
  }

#if !os(macOS)
  /// Resolved document color scheme for the WebView. Per-document
  /// override wins when `enablePerDocumentOverrides` is on; otherwise
  /// the global default applies. visionOS-only — macOS adopts the
  /// system appearance directly.
  var resolvedColorScheme: ColorScheme {
    if Defaults.shared.enablePerDocumentOverrides {
      return colorSchemes.selected.value.colorScheme
    }
    return appModel.colorSchemes.selected.value.colorScheme
  }
#endif

  /// Template whose HTML is currently painted in the WebView, per
  /// the last `BackgroundColorBridge` report. Falls back to the
  /// selected template before the first bridge fire (cold open —
  /// the WebView is system-white, so the selected template's cached
  /// color is the best available placeholder) and when the painted
  /// template's id no longer resolves in the global catalog
  /// (template uninstalled mid-session).
  func renderedTemplate() -> Template {
    if let id = renderedTemplateID,
       let template = appModel.templates.findValue(forID: id)
    {
      return template
    }
    return resolvedTemplate()
  }
}
