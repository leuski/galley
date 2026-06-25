#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import GalleyCoreKit
import KosmosAppKit

struct MarkdownSettingsView: View {
  @Bindable var appModel = AppModel.shared
  @Bindable var defaults = Defaults.shared

  /// Drives the SwiftUI `.fileImporter` for the "Other Application…"
  /// editor row and the "Choose Application…" detail button. The
  /// picker is a single instance attached to `editorPicker`; both
  /// entry points just flip this state.
  @State private var showAppPicker = false

  /// Drives the BBEdit-script-folder picker behind the
  /// "Install scripts…" button.
  @State private var showScriptPicker = false

  /// Non-nil while the install-scripts failure alert is showing.
  /// SwiftUI presents the alert when this is non-nil and clears it on
  /// dismissal.
  @State private var scriptInstallError: String?

  var body: some View {
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

    LabeledContent {
      Toggle(
        "Allow per-window processor and template overrides",
        isOn: $defaults.enablePerDocumentOverrides)
        .labelsHidden()
        .toggleStyle(.switch)
    } label: {
      Text(
        "Allow per-window processor and template overrides")
      Text("""
          Adds a Format menu section that lets each window pin its own \
          Markdown processor or template, overriding the global \
          selection.
          """)
    }
  }

  @ViewBuilder
  private var editorPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent {
        Menu {
          EditorMenuCore(
            model: appModel.editors,
            onRequestAppPicker: { showAppPicker = true })
        } label: {
          Text(appModel.editors.selected.name)
        }
        .fixedSize()
      } label: {
        Text("Editor")
      }
      .modifier(InstallScriptsPickerModifier(
        isPresented: $showScriptPicker,
        errorMessage: $scriptInstallError,
        defaultDestination: selectedScriptingPreset?
          .scriptPickerDefaultDirectory
          ?? URL.applicationSupportDirectory,
        customizationID: selectedScriptingPreset?
          .scriptPickerCustomizationID ?? "is-default",
        onCompletion: handlePickedScriptDestination))
      detailFields
        .modifier(AppBundlePickerModifier(
          isPresented: $showAppPicker,
          onCompletion: handlePickedAppBundle))
    }
  }

  private func handlePickedAppBundle(
    _ result: Result<[URL], any Error>
  ) {
    guard case .success(let urls) = result, let url = urls.first
    else { return }
    appModel.editors.selected = .appBundle(url)
  }

  private func handlePickedScriptDestination(
    _ result: Result<[URL], any Error>
  ) {
    guard case .success(let urls) = result, let destination = urls.first,
      let preset = selectedScriptingPreset
    else { return }
    do {
      try preset.installScripts(to: destination)
      preset.presentInstalledScripts(at: destination)
    } catch {
      scriptInstallError = error.localizedDescription
    }
  }

  /// Currently-selected preset if the user is on a preset row that
  /// ships scripts, otherwise nil. Drives the "Install scripts…"
  /// affordance and its picker.
  private var selectedScriptingPreset: EditorPreset? {
    if case .preset(let preset) = appModel.editors.selected,
       preset.hasScriptKit {
      return preset
    }
    return nil
  }

  @ViewBuilder
  private var detailFields: some View {
    switch appModel.editors.selected {
    case .preset(let preset) where preset.hasScriptKit:
      HStack {
        Spacer()
        Button("Install scripts…") { showScriptPicker = true }
          .padding(.top, 4)
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
          Button("Choose Application…") { showAppPicker = true }
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

}

/// Wraps the app-bundle `.fileImporter` and its `.fileDialog*`
/// configuration. Attached to the Menu's `LabeledContent` rather
/// than the outer `editorPicker` VStack — two `.fileImporter`
/// modifiers on the same host view conflict and only one ends up
/// presentable. Pairing each with a distinct host view (this one
/// on the Menu container, `InstallScriptsPickerModifier` on the
/// VStack) keeps both reachable.
private struct AppBundlePickerModifier: ViewModifier {
  @Binding var isPresented: Bool
  let onCompletion: (Result<[URL], any Error>) -> Void

  func body(content: Content) -> some View {
    content
      .fileImporter(
        isPresented: $isPresented,
        allowedContentTypes: [.applicationBundle],
        allowsMultipleSelection: false,
        onCompletion: onCompletion)
      .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications"))
      .fileDialogConfirmationLabel("Choose")
      .fileDialogCustomizationID("editor.app-bundle")
  }
}

/// Wraps the script-folder `.fileImporter`, its `.fileDialog*` config,
/// and the failure `.alert` as a single modifier. Lives at the
/// `editorPicker` VStack level rather than on the inner `Button`
/// because deeply-nested `.fileImporter` modifiers (Button →
/// LabeledContent → switch case) failed to present. The default
/// destination is supplied per editor via the preset's
/// `scriptPickerDefaultDirectory`, which the preset has already
/// walked up to a directory that exists on disk.
private struct InstallScriptsPickerModifier: ViewModifier {
  @Binding var isPresented: Bool
  @Binding var errorMessage: String?
  let defaultDestination: URL
  let customizationID: String
  let onCompletion: (Result<[URL], any Error>) -> Void

  /// Bridges the optional error to the `.alert(isPresented:)` Bool;
  /// dismissing the alert clears the error.
  private var errorPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })
  }

  func body(content: Content) -> some View {
    content
      .fileImporter(
        isPresented: $isPresented,
        allowedContentTypes: [.folder],
        allowsMultipleSelection: false,
        onCompletion: onCompletion)
      .fileDialogDefaultDirectory(defaultDestination)
      .fileDialogConfirmationLabel("Install")
      .fileDialogMessage("""
        Choose the destination folder for the editor's scripts.
        """)
      .fileDialogCustomizationID(customizationID)
      .alert(
        "Could not install scripts",
        isPresented: errorPresented,
        presenting: errorMessage
      ) { _ in
        Button("OK") { errorMessage = nil }
      } message: { message in
        Text(message)
      }
  }
}

/// Menu rows for the editor picker. Sectioned by kind so presets
/// sit above customURL/appBundle.
///
/// Most rows use the default selection binding. The `.appBundle` row
/// is special-cased: if the slot already has a remembered URL, the
/// row just re-selects it; if not, the row asks the host view to
/// present its `.fileImporter` so the user can pick an app first.
/// The model never receives `.appBundle(nil)` — it only sees
/// `.appBundle(picked)` after a successful pick.
struct EditorMenuCore: View {
  let model: EditorChoice
  let onRequestAppPicker: () -> Void

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
      Toggle(isOn: binding(for: value)) {
        Text(value.name)
      }
    }
  }

  private func binding(for value: EditorChoice.Element) -> Binding<Bool> {
    Binding(
      get: { model.selected.kind == value.kind },
      set: { newValue in
        guard newValue else { return }
        if case .appBundle = value {
          if let url = model.appBundleURL {
            model.selected = .appBundle(url)
          } else {
            onRequestAppPicker()
          }
        } else {
          model.selected = value
        }
      }
    )
  }
}

#Preview {
  MarkdownSettingsView(appModel: AppModel())
}
#endif
