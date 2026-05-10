import Observation

/// State surface required by `SearchField` — a search-style text input
/// with case / whole-word options and a match counter. Conformers
/// expose live query state plus the latest match metadata; the view
/// drives `performSearch()` whenever the query or an option changes.
///
/// The protocol intentionally ignores incremental navigation
/// (next / previous / dismissal) — those are bar-level concerns that
/// the host view wires up separately.
@MainActor
protocol SearchFieldModel: AnyObject, Observable {
  var query: String { get set }
  var ignoresCase: Bool { get set }
  var wholeWord: Bool { get set }
  var matchCount: Int { get }
  var matchIndex: Int { get }
  func performSearch() async
}
