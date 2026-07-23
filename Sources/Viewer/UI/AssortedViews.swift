//
//  AssortedViews.swift
//  Galley
//
//  Created by Anton Leuski on 4/28/26.
//

import GalleyCoreKit
import SwiftUI

struct TemplateMenu: View {
  private let title: LocalizedStringResource?
  private let documentModel: DocumentModel?
  @Environment(AppModel.self) var appModel

  init(
    title: LocalizedStringResource? = "Template",
    globalTitle: LocalizedStringResource? = "Global Template",
    documentModel: DocumentModel? = nil)
  {
    self.documentModel = documentModel
    self.title = (Defaults.shared.enablePerDocumentOverrides
                  && documentModel == nil ? globalTitle : nil) ?? title
  }

  var body: some View {
    if let documentModel,
       Defaults.shared.enablePerDocumentOverrides {
      TemplateMenuContent(title: title, model: documentModel.templates)
    } else {
      TemplateMenuContent(title: title, model: appModel.templates)
    }
  }
}

struct ProcessorMenu: View {
  private let title: LocalizedStringResource
  private let documentModel: DocumentModel?
  @Environment(AppModel.self) var appModel

  init(documentModel: DocumentModel? = nil) {
    self.documentModel = documentModel
    self.title = Defaults.shared.enablePerDocumentOverrides
    && documentModel == nil
    ? "Global Markdown Processor" : "Markdown Processor"
  }

  var body: some View {
    if let documentModel,
       Defaults.shared.enablePerDocumentOverrides {
      ProcessorMenuContent(title: title, model: documentModel.processors)
    } else {
      ProcessorMenuContent(title: title, model: appModel.processors)
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
  private let title: LocalizedStringResource
  private let documentModel: DocumentModel?
  @Environment(AppModel.self) var appModel

  init(documentModel: DocumentModel? = nil) {
    self.documentModel = documentModel
    self.title = Defaults.shared.enablePerDocumentOverrides
    && documentModel == nil ? "Global Color Scheme" : "Color Scheme"
  }

  var body: some View {
    if let documentModel,
       Defaults.shared.enablePerDocumentOverrides {
      ColorSchemeMenuContent(title: title, model: documentModel.colorSchemes)
    } else {
      ColorSchemeMenuContent(title: title, model: appModel.colorSchemes)
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
