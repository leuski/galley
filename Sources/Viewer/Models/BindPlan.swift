import Foundation
import GalleyCoreKit

/// Pure-decision view of "what should `DocumentView.launchTask` do?"
/// given the current state of the SwiftUI scene (binding URL,
/// did-bind flags, persisted history JSON, per-file store).
///
/// Pre-extraction this logic lived inline in `DocumentView.launchTask`,
/// where every "what if restoration brings back a different URL than
/// the binding" / "what if the snapshot has a corrupted index" /
/// "what if didFirstBind already fired before .task did" branch had
/// to be exercised end-to-end through XCUITest. The pure decision is
/// captured here, the side-effecting interpretation stays in the view.
///
/// The interpreter (in `DocumentView`) handles the side effects the
/// pure plan deliberately leaves out:
///   - recording in `RecentDocumentsModel`
///   - consuming the pending scroll-line from `ViewerOpenModel`
///   - awaiting `model.restore` / `model.bind`
struct BindPlan: Equatable {
  /// Zoom factor to apply on every launchTask fire — a JS rule
  /// update for already-bound docs, an HTML <style> seed for the
  /// first render. Defaults to 1.0 when nothing is persisted.
  var zoom: Double

  /// True when state restoration brought back a URL that differs
  /// from the WindowGroup binding's URL. The interpreter must
  /// propagate `templateOverride` and `rendererOverride` into the
  /// per-window choice envelopes so the restored window picks up
  /// the correct processor / template for the *restored* URL,
  /// not the WindowGroup's URL the model was constructed with.
  var applyChoiceOverrides: Bool

  /// Per-file persisted template choice — applied only when
  /// `applyChoiceOverrides` is true.
  var templateOverride: String?

  /// Per-file persisted renderer choice — applied only when
  /// `applyChoiceOverrides` is true.
  var rendererOverride: String?

  /// What the interpreter should do next.
  var action: Action

  enum Action: Equatable {
    /// `model.didFirstBind` is already true — no bind needed; the
    /// interpreter still applies the zoom / override sync above.
    case alreadyBound

    /// Restore from a saved snapshot.
    case restore(
      snapshot: HistorySnapshot,
      scrollY: Double?,
      showsTOC: Bool)

    /// First bind for a freshly-opened target. The target carries any
    /// `?line=N` scroll hint (`DocumentTarget.scrollLine`); the
    /// interpreter forwards it and everything else as-is.
    case initialBind(
      target: DocumentTarget,
      scrollY: Double?,
      showsTOC: Bool)
  }
}

extension BindPlan {
  /// Compute the plan from current scene state. Pure — every input
  /// is a value, every output is a value type.
  ///
  /// `perFileState` abstracts the `[URL: PerFileState]` lookup so
  /// tests can inject a stub without touching the `Defaults`
  /// singleton. Production callers pass
  /// `{ Defaults.shared.perFileStateStore[$0] }`.
  static func decide(
    target: DocumentTarget,
    didFirstBind: Bool,
    didRestore: Bool,
    historyJSON: String,
    perFileState: (URL) -> PerFileState
  ) -> BindPlan {
    // Skip snapshot decode after the restore branch has already
    // fired — `didRestore` is the gate that prevents a re-fire of
    // .task from re-entering restore.
    let snapshot = !didRestore
      ? HistorySnapshot.decode(json: historyJSON)
      : nil
    let restoreURL = snapshot?.currentURL
    let stored = perFileState(restoreURL ?? target.documentURL)

    // Restoration brought back a different URL than the binding —
    // the model was constructed with the binding's URL, so the
    // interpreter must override the per-window choice envelopes.
    let applyOverrides =
      restoreURL != nil && restoreURL != target.documentURL

    let action: Action
    if didFirstBind {
      action = .alreadyBound
    } else if let snapshot {
      action = .restore(
        snapshot: snapshot,
        scrollY: stored.scrollY,
        showsTOC: stored.showsTOC ?? false)
    } else {
      action = .initialBind(
        target: target,
        scrollY: stored.scrollY,
        showsTOC: stored.showsTOC ?? false)
    }

    return BindPlan(
      zoom: stored.pageZoom ?? 1.0,
      applyChoiceOverrides: applyOverrides,
      templateOverride: stored.templatePersistent,
      rendererOverride: stored.rendererPersistent,
      action: action)
  }
}
