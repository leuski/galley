import GalleyCoreKit
import SwiftUI

/// Find-text bar styled after Preview's: a full-width horizontal bar
/// pinned below the toolbar via `.safeAreaInset(edge: .top)`. The
/// magnifying-glass toolbar button toggles `isVisible`; ⌘F drives
/// the same surface from the View menu.
///
/// The text field, options menu, and counter live in `SearchField`;
/// this view owns bar-level chrome (next / previous, dismissal,
/// focus-reveal timing) and the surrounding strip.
///
/// State lives on `DocumentModel` so a window's find session survives
/// file-watcher reloads — `renderCurrent` re-runs the query against
/// the freshly-built DOM when the bar is visible.
struct FindBar<Model>: View
where Model: SearchModel
{
  @Bindable var model: Model

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
      withAnimationAsNeeded(reduceMotion) { model.hide() }
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 8)

      SearchField(
        model: model,
        isFocused: $fieldFocused,
        prompt: "Find",
        onSubmit: { Task { await model.findNext() } },
        onCancel: { dismiss() })

      Button("Done") { dismiss() }
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityIdentifier(ViewerA11yID.Find.close)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
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
    .onChange(of: model.dismissalToken) { dismiss() }
    .onChange(of: fieldFocused) { _, new in
      if !new && model.query.isEmpty {
        dismiss()
      }
    }
  }
}
