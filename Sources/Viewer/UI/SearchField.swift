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
  /// Two-way focus binding from the owner's `@FocusState`.
  var isFocused: FocusState<Bool>.Binding
  let prompt: String
  let onSubmit: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      FindOptionsView(model: model)

      TextField(prompt, text: $model.query)
        .textFieldStyle(.plain)
        .focused(isFocused)
        .onSubmit(onSubmit)
#if os(macOS)
        .onExitCommand(perform: onCancel)
#endif
        .frame(maxWidth: .infinity)
        .onChange(of: model.query) {
          Task { await model.performSearch() }
        }
        .accessibilityIdentifier(ViewerA11yID.Find.field)

      FindMatchStateView(model: model)

      if !model.query.isEmpty {
        if model.match.count > 0 {
          Action.findPrevious(model).button()
            .buttonStyle(.borderless)
          Action.findNext(model).button()
            .buttonStyle(.borderless)
        }

        Action.clear { _ in
          model.query = ""
          isFocused.wrappedValue = true
        }
        .button()
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
    .frame(minWidth: searchMinWidth, maxWidth: searchMaxWidth)
  }
}
