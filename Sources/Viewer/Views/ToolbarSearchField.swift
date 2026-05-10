import SwiftUI

/// Toolbar wrapper around `SearchField` for the Viewer's main
/// document toolbar. Two visual states:
///
/// - **Closed** — a plain magnifying-glass `Button`, sized and
///   styled by the toolbar's default item chrome (Liquid Glass on
///   macOS 26) so it matches sibling icon items.
/// - **Open** — a `SearchField` with the rounded text-field chrome,
///   options menu, match counter, and clear button.
///
/// `isItemSurfaced` is forwarded by the parent so this view can tell
/// when *it* is the live find UI versus when `FindBar` is. Only the
/// active surface should respond to `findDismissalToken`; otherwise
/// both surfaces would race on the dismiss path.
struct ToolbarSearchField: View {
  @Bindable var model: DocumentModel
  let isItemSurfaced: Bool

  @State private var isOpen = false
  /// Plain `@State` instead of `@FocusState` because focus is owned
  /// by `AppKitSearchField` underneath — writing `true` requests
  /// first responder, AppKit reports begin / end editing back.
  @State private var fieldFocused = false

  /// Embedding the animation inside the `.transition` is what
  /// actually controls the swap timing — `withAnimation` and
  /// `.animation(_:value:)` get overridden by SwiftUI's default
  /// identity-change transition for views inside a toolbar item.
  private static let swap: AnyTransition =
    .opacity.animation(.easeInOut(duration: 5.5))

  var body: some View {
    Group {
      if isOpen {
        SearchField(
          model: model,
          isFocused: $fieldFocused,
          prompt: "Search",
          onSubmit: { Task { await model.findNext() } },
          onCancel: close)
          .transition(Self.swap)
      } else {
        // `Label` (vs bare `Image`) is what gives the Customize
        // Toolbar panel a name to show. `.labelStyle(.iconOnly)`
        // keeps the live toolbar rendering as just the glyph.
        Button(action: open) {
          Label("Search", systemImage: "magnifyingglass")
        }
        .labelStyle(.iconOnly)
        .help("Search")
        .transition(Self.swap)
      }
    }
    .onAppear {
      // Re-mount mid-find session (state restoration, the user
      // re-adding the item via Customize Toolbar) should resume in
      // open state.
      if model.isFindVisible { open() }
    }
    .onChange(of: isItemSurfaced) { _, surfaced in
      // Took over from `FindBar` while a session was active —
      // open and reclaim focus so typing keeps working.
      if surfaced && model.isFindVisible { open() }
    }
    .onChange(of: model.isFindVisible) { _, isVisible in
      // External commands (⌘F / ⌘E / Edit menu) drive the flag;
      // mirror that here.
      if isVisible {
        open()
      } else {
        close()
      }
    }
    .onChange(of: model.findDismissalToken) {
      // `Action.find` bumps the dismissal token instead of flipping
      // `isFindVisible` so `FindBar` can choreograph its slide-out.
      // The toolbar field has no slide animation; just close. Only
      // the active surface responds — `FindBar` handles its own.
      guard isItemSurfaced else { return }
      close()
    }
    .onChange(of: fieldFocused) { _, focused in
      // Auto-collapse when focus leaves and the field is empty.
      if !focused && model.findQuery.isEmpty {
        close()
      }
    }
  }

  private func open() {
    if !isOpen { isOpen = true }
    if !model.isFindVisible { model.isFindVisible = true }
    // `AppKitSearchField`'s `updateNSView` will pick this up on the
    // next render and call `makeFirstResponder` async-safe.
    if !fieldFocused { fieldFocused = true }
  }

  private func close() {
    if fieldFocused { fieldFocused = false }
    if isOpen { isOpen = false }
    if model.isFindVisible { model.isFindVisible = false }
  }
}
