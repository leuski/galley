import AppKit
import SwiftUI
import GalleyCoreKit

struct MarkdownSettingsView: View {
  @Bindable var appModel: AppModel
  @Bindable var defaults = Defaults.shared

  var body: some View {
    Section {
      editorPicker

      LabeledContent {
        HStack {
          templatePicker
          revealTemplatesButton
        }
      } label: {
        Text("Template")
      }

      LabeledContent {
        HStack {
          processorPicker
          rediscoverRenderersButton
        }
      } label: {
        Text("Processor")
      }
    }

    Section {
      Toggle(
        "Allow per-window processor and template overrides",
        isOn: $defaults.enablePerDocumentOverrides)
      Text(
        "Adds a Format menu section that lets each window pin its own "
        + "Markdown processor or template, overriding the global "
        + "selection."
      )
      .subtitle()
    }
  }

  @ViewBuilder
  private var editorPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent {
        Menu(appModel.editors.selected.name) {
          EditorMenuCore(model: appModel.editors)
        }
        .fixedSize()
      } label: {
        Text("Еditor")
      }
      detailFields
    }
  }

  @ViewBuilder
  private var detailFields: some View {
    switch appModel.editors.selected {
    case .preset(.bbedit):
      LabeledContent {
        Button("Install scripts…") {
          ScriptInstaller.installScripts(context: [
            "__LOCATION__": Defaults.shared
              .host.galleyPreview.absoluteString
          ])
        }
        .padding(.top, 4)
      } label: {
        Text("")
      }

    case .preset:
      EmptyView()

    case .customURL:
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("URL template")
          Spacer()
          TextField("URL template", text: customURLBinding)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .labelsHidden()
        }
        Text("Use {url}, {path}, and {line} as placeholders.")
          .subtitle()
      }

    case .appBundle:
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(
            "Line numbers are not passed to applications selected this way."
          )
          .subtitle()
          Spacer()
          Button("Choose Application…") { pickAppBundle() }
        }
      }
    }
  }

  @ViewBuilder
  private var templatePicker: some View {
    Menu {
      MenuCore(model: appModel.templates)
    } label: {
      Text(appModel.templates.selected.name)
    }
  }

  @ViewBuilder
  private var processorPicker: some View {
    Menu {
      MenuCore(model: appModel.processors)
    } label: {
      Text(appModel.processors.selected.name)
    }
  }

  @ViewBuilder
  private var revealTemplatesButton: some View {
    Button {
      TemplateStore.shared.revealFolder()
    } label: {
      Image(systemName: "folder")
        .frame(width: 16, height: 16)
    }
    .help("""
      Reveal Templates folder in Finder
      """)
  }

  @ViewBuilder
  private var rediscoverRenderersButton: some View {
    Button {
      ProcessorStore.shared.rediscover()
    } label: {
      Image(systemName: "arrow.clockwise")
        .frame(width: 16, height: 16)
    }
    .help("""
      Re-run shell-based discovery — useful after installing a new processor.
      """)
  }

  /// Reads/writes the customURL template via `selected`. The setter
  /// flows through `EditorChoice.selected.set` which rewrites the
  /// matching slot in `values`, so each keystroke updates both the
  /// active selection and the in-memory customURL slot.
  private var customURLBinding: Binding<String> {
    Binding(
      get: {
        if case .customURL(let template) = appModel.editors.selected {
          return template
        }
        return ""
      },
      set: { newValue in
        appModel.editors.selected = .customURL(template: newValue)
      }
    )
  }

  /// "Choose Application…" — pick a fresh bundle URL even when one is
  /// already set. Goes through `selected.set` so the appBundle slot
  /// in `values` updates too.
  private func pickAppBundle() {
    guard let url = EditorChoice.defaultPickAppBundle() else { return }
    appModel.editors.selected = .appBundle(url)
  }
}

/// Menu rows for the editor picker. Sectioned by kind so presets
/// sit above customURL/appBundle. Driven by `selectedBinding(_:)`
/// like every other choice menu in the app.
struct EditorMenuCore: View {
  let model: EditorChoice

  var body: some View {
    let values = model.values
    DividedSections(sections: [
      values.filter { if case .preset = $0 { return true }; return false },
      values.filter {
        switch $0 {
        case .customURL, .appBundle: return true
        case .preset:                return false
        }
      }
    ], id: \.kind) { value in
      Toggle(value.name, isOn: model.isSelectedBinding(value))
    }
  }
}

#Preview {
  MarkdownSettingsView(appModel: AppModel())
}
