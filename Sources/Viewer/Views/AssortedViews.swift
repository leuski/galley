//
//  AssortedViews.swift
//  MarkdownPreviewer
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
  title: String = "Template",
  globalTitle: String? = nil,
  appModel: AppModel,
  choices templates: SceneTemplateChoice? = nil) -> some View
{
  let title = Defaults.shared.enablePerDocumentOverrides && templates != nil
  ? title : (globalTitle ?? title)
  if let templates, Defaults.shared.enablePerDocumentOverrides {
    TemplateMenu(
      title: title,
      model: templates)
  } else {
    TemplateMenu(
      title: title,
      model: appModel.templates)
  }
}

@ViewBuilder @MainActor
func processorMenu(
  title: String = "Template",
  globalTitle: String? = nil,
  appModel: AppModel,
  choices processors: SceneProcessorChoice? = nil) -> some View
{
  let title = Defaults.shared.enablePerDocumentOverrides && processors != nil
  ? title : (globalTitle ?? title)
  if let processors, Defaults.shared.enablePerDocumentOverrides {
    TemplateMenu(
      title: title,
      model: processors)
  } else {
    TemplateMenu(
      title: title,
      model: appModel.processors)
  }
}
