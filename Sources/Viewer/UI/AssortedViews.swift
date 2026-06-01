//
//  AssortedViews.swift
//  Galley
//
//  Created by Anton Leuski on 4/28/26.
//

import GalleyCoreKit
import SwiftUI

struct SubtitleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

extension View {
  func subtitle() -> some View {
    self.modifier(SubtitleModifier())
  }
}

@ViewBuilder @MainActor
func templateMenu(
  title: LocalizedStringResource? = "Template",
  globalTitle: LocalizedStringResource? = "Global Template",
  appModel: AppModel,
  documentModel: DocumentModel? = nil) -> some View
{
  let title = (Defaults.shared.enablePerDocumentOverrides
               && documentModel == nil ? globalTitle : nil) ?? title
  if let documentModel,
     Defaults.shared.enablePerDocumentOverrides {
    TemplateMenu(title: title, model: documentModel.templates)
  } else {
    TemplateMenu(title: title, model: appModel.templates)
  }
}

@ViewBuilder @MainActor
func processorMenu(
  title: LocalizedStringResource? = "Markdown Processor",
  globalTitle: LocalizedStringResource? = "Global Markdown Processor",
  appModel: AppModel,
  documentModel: DocumentModel? = nil) -> some View
{
  let title = (Defaults.shared.enablePerDocumentOverrides
               && documentModel == nil ? globalTitle : nil) ?? title
  if let documentModel,
     Defaults.shared.enablePerDocumentOverrides {
    ProcessorMenu(title: title, model: documentModel.processors)
  } else {
    ProcessorMenu(title: title, model: appModel.processors)
  }
}

#if !os(macOS)
/// Color-scheme picker menu. visionOS-only — macOS adopts the
/// system appearance directly. Mirrors `templateMenu` /
/// `processorMenu`: when overrides are on AND a document model is
/// supplied, the menu drives the per-window `SceneColorSchemeChoice`
/// (which already exposes a `.global(...)` sentinel row); otherwise
/// it drives the AppModel's global `ColorSchemeChoice`.
@ViewBuilder @MainActor
func colorSchemeMenu(
  title: LocalizedStringResource? = "Color Scheme",
  globalTitle: LocalizedStringResource? = "Global Color Scheme",
  appModel: AppModel,
  documentModel: DocumentModel? = nil) -> some View
{
  let title = (Defaults.shared.enablePerDocumentOverrides
               && documentModel == nil ? globalTitle : nil) ?? title
  if let documentModel,
     Defaults.shared.enablePerDocumentOverrides {
    ColorSchemeMenu(title: title, model: documentModel.colorSchemes)
  } else {
    ColorSchemeMenu(title: title, model: appModel.colorSchemes)
  }
}
#endif
