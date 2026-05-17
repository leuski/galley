#if !os(macOS)

import GalleyCoreKit
import SwiftUI

/// Single settings surface for the visionOS Viewer. Hosted by the
/// `Window("settings")` scene declared in `VisionViewerApp`; reached
/// from the document toolbar's gear button.
///
/// Pane shape mirrors the macOS Settings tabs at content level
/// (General + Markdown) but is a single scrolling surface — visionOS
/// users don't have a tab strip affordance the way macOS does, and
/// the total knob count is small enough to fit on one page.
struct VisionSettingsView: View {
  @Bindable var appModel: AppModel
  @Bindable private var defaults = Defaults.shared

  var body: some View {
    Form {
      generalSection
      markdownSection
    }
    .formStyle(.grouped)
    .padding()
    .navigationTitle("Settings")
  }

  // MARK: - General

  @ViewBuilder
  private var generalSection: some View {
    Section("General") {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Open document")
          Spacer()
          Picker(selection: $defaults.openBehavior) {
            // visionOS has no native window tabbing — the `.newTab`
            // case from `OpenBehavior` is omitted here. v2 will
            // either revive it (Safari-style tabs) or cut it from
            // the enum entirely.
            ForEach(visionOpenBehaviors) { behavior in
              Text(behavior.displayName).tag(behavior)
            }
          } label: { EmptyView() }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        Text("""
          Applies when opening files via Files.app or a deep link \
          while another document window is already open.
          """)
          .subtitle()
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle(
          "Tint window with page background",
          isOn: $defaults.tintWindowWithPageBackground)
        Text("""
          Paints the page background color behind the window glass \
          so the toolbar and sidebar pick up the template tint.
          """)
          .subtitle()
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Color scheme")
          Spacer()
          Picker(selection: $defaults.documentColorScheme) {
            ForEach(DocumentColorScheme.allCases) { scheme in
              Text(scheme.displayName).tag(scheme)
            }
          } label: { EmptyView() }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        Text("""
          Drives the WebView color scheme for rendered documents. \
          Templates that respond to `prefers-color-scheme` swap their \
          CSS variant accordingly.
          """)
          .subtitle()
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle("Show status bar", isOn: $defaults.showsStatusBar)
        Text("""
          Adds a thin bar at the bottom of each document window with \
          word count, character count, and estimated reading time.
          """)
          .subtitle()
      }

      VStack(alignment: .leading, spacing: 4) {
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
          """)
          .subtitle()
      }
    }
  }

  // MARK: - Markdown

  @ViewBuilder
  private var markdownSection: some View {
    Section("Markdown") {
      LabeledContent {
        templateMenu(
          title: "Template",
          appModel: appModel)
      } label: {
        Text("Template")
      }

      Toggle(
        "Allow per-window processor, template, and color-scheme overrides",
        isOn: $defaults.enablePerDocumentOverrides)
      Text("""
        Adds Format-menu entries to each window so an individual \
        document can override the global template or color scheme \
        without changing the defaults.
        """)
        .subtitle()
    }
  }

  /// `OpenBehavior` cases that make sense on visionOS — no native
  /// window tabbing yet, so `.newTab` is hidden. v2 may revive it as
  /// a Safari-style tab strip; until then, exposing it would just
  /// behave identically to `.newWindow` and confuse the user.
  private var visionOpenBehaviors: [OpenBehavior] {
    OpenBehavior.allCases.filter { $0 != .newTab }
  }
}

#endif
