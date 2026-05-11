import GalleyCoreKit
import SwiftUI

let searchMinWidth: CGFloat = 180
let searchMaxWidth: CGFloat = 350
let webViewMinWidth: CGFloat = 600

/// Rounded search field with an inline options menu (case-sensitive /
/// whole-word toggles), a "n of N" match counter, and a clear button —
/// the visual shape Preview and Safari use inside their find bars.
/// Generic over the model so the same view hosts both the live
/// `DocumentModel` find state and the dummy `PreviewSearchFieldModel`
/// used for SwiftUI previews.
///
/// Bar-level concerns (next / previous, dismissal, focus reveal
/// timing) live in the host view; this struct only owns the field
/// chrome and forwards `onSubmit` / `onCancel`.
struct SearchField<Model>: View
where Model: SearchFieldModel
{
  @Bindable var model: Model
  /// Two-way focus binding. Writing `true` requests focus; the
  /// underlying `AppKitSearchField` reports begin / end editing back
  /// through the same binding so callers see real focus changes.
  /// Owner declares `@State var fieldFocused: Bool` and passes
  /// `$fieldFocused`. (`@FocusState` is unreliable for toolbar-
  /// hosted TextFields — see `AppKitSearchField`.)
  @Binding var isFocused: Bool
  let prompt: String
  let onSubmit: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      optionsMenu

      AppKitSearchField(
        text: $model.query,
        prompt: prompt,
        isFocused: $isFocused,
        onSubmit: onSubmit,
        onCancel: onCancel)
        .frame(maxWidth: .infinity)
        .onChange(of: model.query) {
          Task { await model.performSearch() }
        }
        .accessibilityIdentifier(ViewerA11yID.Find.field)

      countLabel

      if !model.query.isEmpty {
        if model.matchCount > 0 {
          Action.findPrevious(model).toolbarItem(imageOnly: true)
            .buttonStyle(.borderless)
          Action.findNext(model).toolbarItem(imageOnly: true)
            .buttonStyle(.borderless)
        }

        Button {
          model.query = ""
          isFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear")
        .accessibilityLabel(Text("Clear"))
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.background))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(.separator))
    // Flexible width. `ToolbarSurfacing`'s Auto Layout constraints
    // are what `NSToolbar` actually consults to size the cell; this
    // `.frame` lets the SwiftUI view fill whatever the toolbar
    // gives it instead of capping inside a larger cell.
    .frame(minWidth: searchMinWidth, maxWidth: searchMaxWidth)
  }

  /// Dropdown anchored to the magnifying-glass glyph, mirroring the
  /// affordance Safari and Preview use to host find options. Each
  /// toggle re-runs the search through `.onChange` so highlights
  /// update immediately.
  @ViewBuilder
  private var optionsMenu: some View {
    Menu {
      Toggle("Ignore Case", isOn: $model.ignoresCase)
        .accessibilityIdentifier(ViewerA11yID.Find.ignoreCase)

      Toggle("Whole Word", isOn: $model.wholeWord)
        .accessibilityIdentifier(ViewerA11yID.Find.wholeWord)
    } label: {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.visible)
    .help("Find options")
    .accessibilityLabel(Text("Find options"))
    .accessibilityIdentifier(ViewerA11yID.Find.optionsMenu)
    .onChange(of: model.ignoresCase) {
      Task { await model.performSearch() }
    }
    .onChange(of: model.wholeWord) {
      Task { await model.performSearch() }
    }
  }

  /// "n of N" indicator. Empty while the query is empty (no search
  /// has run) and "No results" when the query yielded zero matches —
  /// both clearer than a bare "0 of 0".
  @ViewBuilder
  private var countLabel: some View {
    if model.query.isEmpty {
      EmptyView()
    } else if model.matchCount == 0 {
      Text("No results")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    } else {
      Text("\(model.matchIndex + 1) of \(model.matchCount)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}
