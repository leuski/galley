import GalleyCoreKit
import SwiftUI

/// Table-of-contents sidebar for a document window. Reads
/// `model.headings` (refreshed on every load by the TOCBridge user
/// script) and lets the user jump to any heading by clicking its
/// row. Indentation reflects heading depth — `<h1>` flush left, each
/// step deeper adds a fixed inset.
struct TOCSidebar: View {
  @Bindable var model: DocumentModel

  /// Inset per level beyond the first. Tuned so an h6 still leaves
  /// room for ~20 characters of text in the standard 220 pt sidebar.
  private static let indentPerLevel: CGFloat = 12

  /// Smallest level seen in the document — usually 1, but some docs
  /// start at h2. Subtracting it from each row's level keeps the
  /// outermost row flush left no matter what depth the doc starts at.
  private var baseLevel: Int {
    model.headings.map(\.level).min() ?? 1
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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(model.headings) { heading in
          row(for: heading)
        }
      }
      .padding(.vertical, 8)
    }
  }

  private func row(for heading: TOCEntry) -> some View {
    let isActive = model.activeHeadingID == heading.id
    return Button {
      Task { await model.scrollToHeading(id: heading.id) }
    } label: {
      Text(heading.text)
        .font(font(for: heading.level))
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .padding(.leading, 16 + indent(for: heading.level))
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isActive: isActive))
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.12), value: isActive)
  }

  @ViewBuilder
  private func rowBackground(isActive: Bool) -> some View {
    if isActive {
      Color.accentColor.opacity(0.15)
    } else {
      Color.clear
    }
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
