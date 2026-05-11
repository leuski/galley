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
/// Both views are mounted at all times in a `ZStack`; only their
/// opacity / hit-test / frame change with `isOpen`. The structural
/// reason is **not** style: a conditional `if isOpen { SearchField }
/// else { Button }` makes SwiftUI swap the toolbar item's hosted
/// view type on every open, which provoked `NSToolbar` to swap
/// `NSToolbarItem.view` out from under SwiftUI's hosting on the
/// *second* expand — detaching the focused field with no recovery
/// path. With a single stable SwiftUI subtree, the host view's
/// identity is constant and the toolbar never replaces the slot.
///
/// `surfacing.isItemSurfaced` tells whether *we* are the live find
/// UI right now or whether `FindBar` is. Only the active surface
/// should react to `dismissalToken`; otherwise both surfaces race
/// on the dismiss path.
struct ToolbarSearchField<Model>: View
where Model: SearchModel
{
  @Bindable var model: Model
  /// Single source of truth for "am I in the visible toolbar items
  /// right now." `@Observable`, so reading `surfacing.isItemSurfaced`
  /// in the body / `.onChange(of:)` triggers re-renders.
  let surfacing: ToolbarSurfacing

  @State private var isOpen = false
  /// Plain `@State` instead of `@FocusState` because focus is owned
  /// by `AppKitSearchField` underneath — writing `true` requests
  /// first responder, AppKit reports begin / end editing back.
  @State private var fieldFocused = false
  /// Timestamp of the last `open()`. Used by the blur handler to
  /// distinguish a user-initiated click-away from a transient
  /// focus drop caused by AppKit shuffling our hosted view during
  /// the post-expansion layout settle.
  @State private var openedAt: Date?

  var body: some View {
    Label {
      Text("Search")
    } icon: {
      ZStack {
        SearchField(
          model: model,
          isFocused: $fieldFocused,
          prompt: "Search",
          onSubmit: { Task { await model.findNext() } },
          onCancel: close,
          // Defensive safety net for the (now-fixed) bug where
          // `NSToolbar` would steal `NSToolbarItem.view` on the
          // second expand. If the live field ever loses its window
          // again, fall through to `FindBar`. Should not fire under
          // the always-mounted ZStack design but cheap to keep.
          onLostWindow: { surrenderToFindBar(resetExpanded: true) })
          .opacity(isOpen ? 1 : 0)
          .allowsHitTesting(isOpen)
          // Collapse to zero while closed so `ToolbarSurfacing`'s
          // `compactWidth` constraint doesn't fight `SearchField`'s
          // internal `minWidth: 180`.
          .frame(width: isOpen ? nil : 0)

        // `Label` (vs bare `Image`) is what gives the Customize
        // Toolbar panel a name to show. `.labelStyle(.iconOnly)`
        // keeps the live toolbar rendering as just the glyph.
        Button(action: open) {
          Image(systemName: "magnifyingglass")
        }
        .opacity(isOpen ? 0 : 1)
        .allowsHitTesting(!isOpen)
      }
    }
    .help("Search")
    .accessibilityLabel(Text("Search"))
    .onAppear {
      // Re-mount mid-find session (state restoration, the user
      // re-adding the item via Customize Toolbar) should resume in
      // open state.
      if model.isVisible { open() }
    }
    .onChange(of: surfacing.isItemSurfaced) { _, surfaced in
      if surfaced {
        // Took over from `FindBar` while a session was active —
        // open and reclaim focus so typing keeps working.
        if model.isVisible { open() }
      } else if isOpen {
        // `NSToolbar` pushed us into overflow mid-session. Hand off
        // to `FindBar` without resetting `surfacing.isExpanded` —
        // that would let `NSToolbar` yank us back into the toolbar
        // and re-trigger the same overflow.
        surrenderToFindBar(resetExpanded: false)
      }
    }
    .onChange(of: model.isVisible) { _, isVisible in
      // External commands (⌘F / ⌘E / Edit menu) drive the flag;
      // mirror that here.
      if isVisible {
        open()
      } else {
        close()
      }
    }
    .onChange(of: model.dismissalToken) {
      // `Action.find` bumps the dismissal token instead of flipping
      // `isFindVisible` so `FindBar` can choreograph its slide-out.
      // The toolbar field has no slide animation; just close. After
      // `surrenderToFindBar()` we're still surfaced but no longer
      // the live UI, so gate on `isOpen`.
      guard isOpen else { return }
      close()
    }
    .onChange(of: fieldFocused) { _, focused in
      // `surrenderToFindBar()` writes `fieldFocused = false` and
      // flips `isOpen = false`; this handler still fires on the
      // surrender write. Skip when we're already out of the open
      // state.
      guard isOpen, !focused, model.query.isEmpty else { return }
      // Within a short window of opening, treat blur as transient —
      // AppKit can shuffle the hosted view during its layout settle
      // and drop first responder before the dust clears. Re-grant
      // focus rather than dismiss.
      if let openedAt, Date().timeIntervalSince(openedAt) < 0.25 {
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(50))
          if isOpen && model.isVisible { fieldFocused = true }
        }
        return
      }
      // The blur fires before KVO on `\.visibleItems` propagates —
      // kick a synchronous refresh first so we read live state.
      surfacing.refreshNow()
      if !surfacing.isItemSurfaced {
        // Blur-driven surrender = overflow case (we're no longer
        // in visibleItems). Don't reset `isExpanded` or NSToolbar
        // would pull us back, re-triggering the cycle.
        surrenderToFindBar(resetExpanded: false)
      } else {
        close()
      }
    }
  }

  private func open() {
    // Force a fresh read before deciding the path — `containsItem`
    // can lag the AppKit state (`willAddItemNotification` fires
    // before the item enters `toolbar.items`/`visibleItems`, and
    // `\.visibleItems` isn't reliably KVO-observable), so the cached
    // value may be `false` even when the user clearly just clicked
    // our visible toolbar button.
    surfacing.refreshNow()
    // Off-toolbar (overflowed / hidden / removed) — just raise the
    // find session and let `FindBar` mount as the live surface.
    guard surfacing.isItemSurfaced else {
      if !model.isVisible { model.isVisible = true }
      return
    }
    surfacing.isExpanded = true
    if !isOpen { isOpen = true }
    if !model.isVisible { model.isVisible = true }
    // `AppKitSearchField`'s `updateNSView` picks this up on the
    // next render and calls `makeFirstResponder` async-safe.
    if !fieldFocused { fieldFocused = true }
    openedAt = Date()
  }

  private func close() {
    openedAt = nil
    if fieldFocused { fieldFocused = false }
    if isOpen { isOpen = false }
    if model.isVisible { model.isVisible = false }
    // Snap the `NSToolbarItem` back to its compact width so the
    // closed-state button sits flush with the sibling toolbar
    // items.
    surfacing.isExpanded = false
  }

  /// Hand the live find session off to `FindBar` without ending the
  /// session. Two callers:
  ///
  /// 1. **Overflow** (`resetExpanded: false`) — `NSToolbar` moved
  ///    our cell into the overflow menu. Keep `isExpanded = true`
  ///    so flipping to compact doesn't pull us back, then expand
  ///    again, etc.
  /// 2. **Detach** (`resetExpanded: true`) — defensive safety net
  ///    for the (now-fixed) NSToolbar view-swap bug. The cell is
  ///    not in overflow; `containsItem` is still `true` so
  ///    `isToolbarActive` would keep gating `FindBar` off unless
  ///    we also drop `isExpanded`.
  private func surrenderToFindBar(resetExpanded: Bool) {
    openedAt = nil
    if fieldFocused { fieldFocused = false }
    if isOpen { isOpen = false }
    // model.isVisible stays true so `FindBar` mounts.
    if resetExpanded, surfacing.isExpanded {
      surfacing.isExpanded = false
    }
  }
}
