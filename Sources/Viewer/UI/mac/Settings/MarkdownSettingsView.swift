#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import GalleyCoreKit

struct MarkdownSettingsView: View {
  @Environment(AppModel.self) var appModel
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
          EditorChoiceElement(model: appModel.editors.selected)
        }
        .fixedSize()
      } label: {
        Text("Editor")
      }
      .modifier(InstallScriptsPickerModifier(
        isPresented: $showScriptPicker,
        errorMessage: $scriptInstallError,
        defaultDestination: appModel.editors.selected
          .scriptPickerDefaultDirectory,
        customizationID: appModel.editors.selected
          .scriptPickerCustomizationID,
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
    Defaults.shared.editorOtherApplication = url
    appModel.editors.selected = EditorStore.shared.otherApplication
  }

  private func handlePickedScriptDestination(
    _ result: Result<[URL], any Error>
  ) {
    guard case .success(let urls) = result, let destination = urls.first
    else { return }
    do {
      let editor = appModel.editors.selected
      guard editor.scriptBundleName != nil else { return }
      try editor.installScripts(to: destination)
      editor.presentInstalledScripts(at: destination)
    } catch {
      scriptInstallError = error.localizedDescription
    }
  }

  @ViewBuilder
  private var detailFields: some View {
    switch appModel.editors.selected {
    case let value where value.scriptBundleName != nil:
      HStack {
        Spacer()
        Button("Install scripts…") { showScriptPicker = true }
          .padding(.top, 4)
      }

    case EditorStore.shared.customURLScheme:
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("URL template")
          Spacer()
          TextField("URL template", text: $defaults.editorCustomURL)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .labelsHidden()
        }
        Text("Use {url}, {path}, and {line} as placeholders.")
          .subtitle()
      }

    case EditorStore.shared.otherApplication:
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
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private var templatePicker: some View {
    Menu {
      SelectableMenuCore(model: appModel.templates)
    } label: {
      Text(appModel.templates.selected.description)
    }
  }

  @ViewBuilder
  private var processorPicker: some View {
    Menu {
      SelectableMenuCore(model: appModel.processors)
    } label: {
      Text(appModel.processors.selected.description)
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

struct EditorChoiceElement: View {
  let model: EditorChoice.Element

  var body: some View {
    if let image = model.url?.icon {
      Label {
        Text(model.description)
      } icon: {
        image
          .resizable()
          .frame(width: 16, height: 16)
      }
    } else {
      Text(model.description)
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
/// Renders an application's Finder icon at menu-row size. Keeping the
/// `NSWorkspace.icon(forFile:)` lookup and `Image(nsImage:)` bridge
/// inside a view means the model layer never handles an `NSImage`.
struct EditorMenuCore: View {
  let model: EditorChoice
  let onRequestAppPicker: () -> Void

  var body: some View {
    let values = model.elements
      .reduce(into: [:]) { result, value in
        result[value.section, default: []].append(value)
      }
      .sorted { $0.key < $1.key }
      .map { $0.value }
    DividedSections(sections: values, id: \.id) { value in
      Toggle(isOn: binding(for: value)) {
        EditorChoiceElement(model: value)
      }
      .disabled(!value.isAvailable)
    }
  }

  private func binding(for value: EditorChoice.Element) -> Binding<Bool> {
    Binding(
      get: { model.selected.id == value.id },
      set: { newValue in
        guard newValue else { return }
        if value == EditorStore.shared.otherApplication {
          if nil != Defaults.shared.editorOtherApplication {
            model.selected = EditorStore.shared.otherApplication
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
  MarkdownSettingsView()
    .environment(AppModel())
}
#endif
