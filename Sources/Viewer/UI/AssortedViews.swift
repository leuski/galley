//
//  AssortedViews.swift
//  Galley
//
//  Created by Anton Leuski on 4/28/26.
//

import GalleyCoreKit
import SwiftUI

@MainActor
func menuPolicy<Local, Global>(
  appModel: Global,
  documentModel: Local?,
  localTitle: LocalizedStringResource,
  globalTitle: LocalizedStringResource)
// swiftlint:disable:next large_tuple
-> (LocalizedStringResource, Local?, Global)
where Local: Selectable,
      Local.Element == Local.Selection,
      Local.Element: SectionedChoiceValue & Identifiable,
      Global: Selectable,
      Global.Element == Global.Selection,
      Global.Element: SectionedChoiceValue & Identifiable
{
  if let documentModel, Defaults.shared.enablePerDocumentOverrides {
    return (localTitle, documentModel, appModel)
  }
  return (
    Defaults.shared.enablePerDocumentOverrides
    && documentModel == nil ? globalTitle : localTitle,
    documentModel, appModel)
}

struct TemplateMenu: View {
  let documentModel: DocumentModel?
  @Environment(AppModel.self) var appModel

  var body: some View {
    let (title, local, global) = menuPolicy(
      appModel: appModel.templates,
      documentModel: documentModel?.templates,
      localTitle: "Template",
      globalTitle: "Global Template")
    if let local {
      templateMenuContent(title: title, model: local)
    } else {
      templateMenuContent(title: title, model: global)
    }
  }
}

struct ProcessorMenu: View {
  let documentModel: DocumentModel?
  @Environment(AppModel.self) var appModel

  var body: some View {
    let (title, local, global) = menuPolicy(
      appModel: appModel.processors,
      documentModel: documentModel?.processors,
      localTitle: "Markdown Processor",
      globalTitle: "Global Markdown Processor")
    if let local {
      processorMenuContent(title: title, model: local)
    } else {
      processorMenuContent(title: title, model: global)
    }
  }
}

#if !os(macOS)
/// Color-scheme picker menu. visionOS-only — macOS adopts the
/// system appearance directly. Mirrors `templateMenu` /
/// `processorMenu`: when overrides are on AND a document model is
/// supplied, the menu drives the per-window `SceneColorSchemeChoice`
/// (which already exposes a `.global(...)` sentinel row); otherwise
/// it drives the AppModel's global `ColorSchemeChoice`.
struct ColorSchemeMenu: View {
  let documentModel: DocumentModel?
  @Environment(AppModel.self) var appModel

  var body: some View {
    let (title, local, global) = menuPolicy(
      appModel: appModel.colorSchemes,
      documentModel: documentModel?.colorSchemes,
      localTitle: "Color Scheme",
      globalTitle: "Global Color Scheme")
    if let local {
      colorSchemeMenuContent(title: title, model: local)
    } else {
      colorSchemeMenuContent(title: title, model: global)
    }
  }
}
#endif

struct ReadingSpeedStepper: View {
  @Bindable var defaults = Defaults.shared
  let spacing: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      LabeledContent("Reading speed") {
        Stepper(
          value: $defaults.readingWordsPerMinute,
          in: 50...600,
          step: 10
        ) {
          Text("\(defaults.readingWordsPerMinute) wpm")
            .monospacedDigit()
        }
      }
      Text("""
            Words per minute used to estimate reading time in the \
            status bar.
            """
      )
      .subtitle()
    }
  }
}
