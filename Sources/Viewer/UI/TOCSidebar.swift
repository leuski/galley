import GalleyCoreKit
import SwiftUI

/// Table-of-contents sidebar for a document window. Reads
/// `model.headings` (refreshed on every load by the TOCBridge user
/// script) and lets the user jump to any heading by clicking its
/// row. Indentation reflects heading depth — `<h1>` flush left, each
/// step deeper adds a fixed inset.
struct TOCSidebar: View {
  @Bindable var model: TOCBridge
  let action: @MainActor (TOCEntry.ID) -> Void

  /// Inset per level beyond the first. Tuned so an h6 still leaves
  /// room for ~20 characters of text in the standard 220 pt sidebar.
  private static let indentPerLevel: CGFloat = 12

  /// Smallest level seen in the document — usually 1, but some docs
  /// start at h2. Subtracting it from each row's level keeps the
  /// outermost row flush left no matter what depth the doc starts at.
  private var baseLevel: Int {
    model.headings.map(\.level).min() ?? 1
  }

  var selection: Binding<TOCEntry.ID?> {
    .init { model.activeHeadingID } set: { newValue in
      model.activeHeadingID = newValue
      if let newValue {
        action(newValue)
      }
    }
  }

  var body: some View {
    Group {
      if model.headings.isEmpty {
        emptyState
      } else {
        list
      }
    }
  }

  /// `ScrollView` + `LazyVStack` rather than `List` so every tab's
  /// sidebar starts at a deterministic top inset. SwiftUI's
  /// `.listStyle(.sidebar)` applies an automatic top inset that
  /// varies with content metrics, so two tabs would render their
  /// first row at different y-positions — visible as content "jumping"
  /// when the user switches tabs.
  private var list: some View {
    List(model.headings, selection: selection) { heading in
      Text(heading.text)
        .id(heading.id)
        .font(font(for: heading.level))
        .lineLimit(2)
        .truncationMode(.tail)
        .padding(.leading, indent(for: heading.level))
    }
#if os(visionOS)
    .padding(.top, 16)
#endif
    .listStyle(.sidebar)
  }

  private var emptyState: some View {
    VStack {
      Text("No headings")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func indent(for level: Int) -> CGFloat {
    let depth = max(0, level - baseLevel)
    return CGFloat(depth) * Self.indentPerLevel
  }

  /// Slightly weight the top-level rows. Deeper levels stay at
  /// regular weight so the visual hierarchy comes from indentation,
  /// not a barrage of styles.
  private func font(for level: Int) -> Font {
    level == baseLevel ? .body.weight(.semibold) : .body
  }
}
