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
  title: LocalizedStringResource? = nil,
  globalTitle: LocalizedStringResource? = nil,
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
  title: LocalizedStringResource? = nil,
  globalTitle: LocalizedStringResource? = nil,
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
/// system appearance directly. Mirrors the template/processor
/// menus' per-document override pattern: when overrides are on AND
/// a document model is supplied, the menu drives the per-document
/// slot with a "Global Color Scheme" row clearing the override;
/// otherwise it drives `Defaults.shared.documentColorScheme`.
@ViewBuilder @MainActor
func colorSchemeMenu(
  title: LocalizedStringResource = "Color Scheme",
  globalTitle: LocalizedStringResource? = nil,
  documentModel: DocumentModel? = nil) -> some View
{
  let resolvedTitle: LocalizedStringResource = (
    Defaults.shared.enablePerDocumentOverrides && documentModel == nil
    ? globalTitle : nil) ?? title
  Menu {
    if Defaults.shared.enablePerDocumentOverrides,
       let documentModel
    {
      Toggle(
        "Global Color Scheme",
        isOn: Binding(
          get: { documentModel.documentColorScheme == nil },
          set: { isOn in
            if isOn { documentModel.documentColorScheme = nil }
          }))
      Divider()
      ForEach(DocumentColorScheme.allCases) { value in
        Toggle(
          isOn: Binding(
            get: { documentModel.documentColorScheme == value },
            set: { isOn in
              if isOn { documentModel.documentColorScheme = value }
            })
        ) {
          Text(value.displayName)
        }
      }
    } else {
      ForEach(DocumentColorScheme.allCases) { value in
        Toggle(
          isOn: Binding(
            get: { Defaults.shared.documentColorScheme == value },
            set: { isOn in
              if isOn { Defaults.shared.documentColorScheme = value }
            })
        ) {
          Text(value.displayName)
        }
      }
    }
  } label: {
    Label(resolvedTitle, systemImage: "circle.lefthalf.filled")
  }
}
#endif
