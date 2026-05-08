import GalleyCoreKit
import SwiftUI

/// Find-text bar styled after Preview's: a full-width horizontal bar
/// pinned below the toolbar via `.safeAreaInset(edge: .top)`. The
/// magnifying-glass toolbar button toggles `isFindVisible`; ⌘F drives
/// the same surface from the View menu.
///
/// State lives on `DocumentModel` so a window's find session survives
/// file-watcher reloads — `renderCurrent` re-runs the query against
/// the freshly-built DOM when the bar is visible.
struct FindBar: View {
  @Bindable var model: DocumentModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var fieldFocused: Bool

  /// Roughly matches SwiftUI's `.default` transition duration. Focus
  /// is granted only after the slide-in completes and dropped one
  /// frame before the slide-out, so the focus ring never renders over
  /// content the bar is sliding past.
  private var transitionMillis: Int { reduceMotion ? 0 : 350 }

  /// Mirrors the `withAnimation`/reduce-motion gate used by
  /// `Action.toggleTOC` and `Action.toggleFind`. Centralizes the
  /// guard so every dismissal path animates consistently. Drops
  /// focus first and lets SwiftUI render one frame without the focus
  /// ring before the slide-out begins.
  private func dismiss() {
    fieldFocused = false
    Task {
      try? await Task.sleep(for: .milliseconds(50))
      withAnimationAsNeeded(reduceMotion) { model.hideFind() }
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      optionsMenu

      TextField("Find", text: $model.findQuery)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
        .focused($fieldFocused)
        .onSubmit { Task { await model.findNext() } }
        .onChange(of: model.findQuery) {
          Task { await model.performFind() }
        }
        .onExitCommand { dismiss() }
        .accessibilityIdentifier(ViewerA11yID.Find.field)

      countLabel

      Spacer(minLength: 8)

      Action.findPrevious.toolbarItem(model: model, imageOnly: true)
        .buttonStyle(.borderless)
      Action.findNext.toolbarItem(model: model, imageOnly: true)
        .buttonStyle(.borderless)

      Button("Done") { dismiss() }
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityIdentifier(ViewerA11yID.Find.close)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .accessibilityIdentifier(ViewerA11yID.Find.toolbar)
    .task {
      // Wait for the slide-in to settle before focusing the field —
      // otherwise the focus ring travels with the bar through the
      // toolbar region above.
      try? await Task.sleep(for: .milliseconds(transitionMillis))
      fieldFocused = true
    }
    .onChange(of: model.findDismissalToken) { dismiss() }
  }

  /// Dropdown anchored to the magnifying-glass glyph, mirroring the
  /// affordance Safari and Preview use to host find options. Each
  /// toggle re-runs the search through `.onChange` so the highlights
  /// update immediately.
  @ViewBuilder
  private var optionsMenu: some View {
    Menu {
      Toggle("Ignore Case", isOn: Binding(
        get: { !model.findCaseSensitive },
        set: { model.findCaseSensitive = !$0 }))
        .accessibilityIdentifier(ViewerA11yID.Find.ignoreCase)

      Toggle("Whole Word", isOn: $model.findWholeWord)
        .accessibilityIdentifier(ViewerA11yID.Find.wholeWord)
    } label: {
      Image(systemName: "magnifyingglass")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Find options")
    .accessibilityLabel(Text("Find options"))
    .accessibilityIdentifier(ViewerA11yID.Find.optionsMenu)
    .onChange(of: model.findCaseSensitive) {
      Task { await model.performFind() }
    }
    .onChange(of: model.findWholeWord) {
      Task { await model.performFind() }
    }
  }

  /// "n of N" indicator. Shows nothing while the query is empty (no
  /// search has run yet) and "No results" when the query yielded
  /// zero matches — both clearer than a bare "0 of 0".
  @ViewBuilder
  private var countLabel: some View {
    if model.findQuery.isEmpty {
      EmptyView()
    } else if model.findMatchCount == 0 {
      Text("No results")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    } else {
      Text("\(model.findMatchIndex + 1) of \(model.findMatchCount)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}
