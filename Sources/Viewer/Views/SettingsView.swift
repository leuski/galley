import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GalleyCoreKit

/// Settings tab. The editor row drives a `Menu` of every preset plus
/// "Custom URL Scheme" and "Other Application"; the conditional
/// fields below let the user supply a URL template or pick an
/// `.app` bundle.
struct SettingsView: View {
  @Bindable var appModel: AppModel
  @Bindable var defaults = Defaults.shared

  @State private var portString: String = String(Defaults.shared.port)

  init(appModel: AppModel) {
    self.appModel = appModel
  }

  @ViewBuilder
  var editorPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent {
        Menu(appModel.editors.selected.name) {
          EditorMenuCore(model: appModel.editors)
        }
        .fixedSize()
      } label: {
        Text("Markdown editor")
      }
      detailFields
    }
  }

  @ViewBuilder
  private var detailFields: some View {
    switch appModel.editors.selected {
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
  var openDocumentPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Open document")
        Spacer()
        Picker(selection: $defaults.openBehavior) {
          ForEach(OpenBehavior.allCases) { behavior in
            Text(behavior.displayName).tag(behavior)
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      Text("""
            Applies when opening files via Finder, the Open dialog, or \
            Open Recent. With no existing window, a new window is \
            always used.
            """
      )
      .subtitle()
    }
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
  private var templatePicker: some View {
    Menu {
      MenuPickerCore(model: appModel.templates) {
        Defaults.shared.templatePersistent = $0
      }
    } label: {
      Text(appModel.templates.selected.name)
    }
  }

  @ViewBuilder
  private var processorPicker: some View {
    Menu {
      MenuPickerCore(model: appModel.processors) {
        Defaults.shared.rendererPersistent = $0
      }
    } label: {
      Text(appModel.processors.selected.name)
    }
  }

  var body: some View {
    Form {
      Section {
        openDocumentPicker
      }

      Section {
        editorPicker
        if appModel.editors.selected == .preset(.bbedit) {
          LabeledContent {
            Button("Install scripts…") {
              ScriptInstaller.installScripts(context: [
                "__LOCATION__": Defaults.shared
                  .host.appendingPreviewPath().absoluteString
              ])
            }
          } label: {
            Text("Integration")
          }
        }

        LabeledContent {
          HStack {
            processorPicker
            rediscoverRenderersButton
          }
        } label: {
          Text("Processor")
        }

        LabeledContent {
          HStack {
            templatePicker
            revealTemplatesButton
          }
        } label: {
          Text("Template")
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

      Section("Markdown Preview Server") {
        Toggle("Run server", isOn: serverEnabledBinding)
        Text(
          "When on, a background server makes documents available in any "
          + "browser. Registered as a login item so it restarts after "
          + "logout."
        )
        .subtitle()

        LabeledContent {
          TextField("", text: $portString)
            .labelsHidden()
            .onSubmit { commitPort() }
            .frame(width: 80)
        } label: {
          Text("Port")
          Text("""
              Default: \(String(GalleyConstants.defaultPort)). \
              The server binds to 127.0.0.1 only.
              """)
          .fixedSize(horizontal: true, vertical: false)
        }
      }
    }
    .padding()
    .formStyle(.grouped)
    .frame(minWidth: 580, maxWidth: 580, minHeight: 360)
    .onChange(of: Defaults.shared.port) { _, newPort in
      portString = String(newPort)
    }
  }

  private var serverEnabledBinding: Binding<Bool> {
    Binding(
      get: { ServerAgent.isEnabled },
      set: { ServerAgent.setEnabled($0) }
    )
  }

  private func commitPort() {
    guard let value = UInt16(portString), value > 0 else {
      portString = String(Defaults.shared.port)
      return
    }
    Defaults.shared.port = value
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
  SettingsView(appModel: AppModel())
}
