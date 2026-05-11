import AppKit
import Observation

/// Tracks whether a specific toolbar item is currently surfaced in
/// the host window's `NSToolbar`. "Surfaced" means the toolbar is
/// visible, the item identifier is present, *and* the item is
/// currently rendering in the toolbar (not pushed into the overflow
/// "extras" menu because the window is too narrow).
///
/// Used by `DocumentView` to decide whether the toolbar's
/// `ToolbarSearchField` is the live find UI or whether the
/// `safeAreaInset` `FindBar` should appear instead. Also bumps the
/// item's `visibilityPriority` to `.high` so it's the last to be
/// kicked into overflow when the toolbar runs out of room.
///
/// Observation strategy:
///
/// - `\NSWindow.toolbar` with `[.initial, .new]` — fires immediately
///   on attach (so we get the current toolbar synchronously) and
///   every time SwiftUI replaces it. This is the bind point for the
///   per-toolbar observers below.
/// - `\NSToolbar.isVisible` — picks up View > Show / Hide Toolbar.
/// - `NSToolbar.willAddItem` / `didRemoveItem` notifications — pick
///   up both the initial item population and Customize Toolbar
///   drag-in / drag-out.
/// - `NSWindow.didResize` — picks up the window crossing the width
///   threshold where the item moves between visible and overflow.
@MainActor
@Observable
final class ToolbarSurfacing {
  let itemIdentifier: String

  /// Width pinned on the `NSToolbarItem` while the host view reports
  /// itself "compact" (`isExpanded == false`). 0 = leave the
  /// `minSize` / `maxSize` alone.
  let compactWidth: CGFloat
  /// Lower / upper bound the `NSToolbarItem`'s flexible width range
  /// takes while the host view is `isExpanded == true`. With
  /// `expandedMin < expandedMax`, `NSToolbar` lays the cell out
  /// flexibly within the range based on available space.
  let expandedMinWidth: CGFloat
  let expandedMaxWidth: CGFloat

  /// Identifiers of sibling toolbar items that should be biased
  /// toward overflow before this one. Their `visibilityPriority`
  /// is forced to `.low`, while ours stays at `.user`, so the
  /// priority differential is large enough that `NSToolbar`'s
  /// reflow consistently picks them to overflow instead of us.
  let lowPriorityIdentifiers: Set<String>

  /// Toolbar's `isVisible` — flips with View > Show/Hide Toolbar
  /// (⌥⌘T). Independent of customization.
  private(set) var isVisible: Bool = false

  /// Whether `itemIdentifier` is currently rendering in the toolbar
  /// (i.e., in `NSToolbar.visibleItems`, not in the overflow menu).
  /// False either when the user has dragged the item out via
  /// Customize Toolbar or when the window is too narrow to fit it.
  private(set) var containsItem: Bool = false

  var isItemSurfaced: Bool { isVisible && containsItem }

  /// Set by the host view to indicate its current visual state.
  /// Toggling this re-applies the matching size constraints to the
  /// underlying `NSToolbarItem` and forces an `NSToolbar` reflow.
  var isExpanded: Bool = false {
    didSet {
      if oldValue != isExpanded { refreshNow() }
    }
  }

  @ObservationIgnored
  private weak var window: NSWindow?
  @ObservationIgnored
  private var toolbarObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var visibilityObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var visibleItemsObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var notificationTokens: [NSObjectProtocol] = []

  init(
    itemIdentifier: String,
    compactWidth: CGFloat = 0,
    expandedMinWidth: CGFloat = 0,
    expandedMaxWidth: CGFloat = 0,
    lowPriorityIdentifiers: Set<String> = []
  ) {
    self.itemIdentifier = itemIdentifier
    self.compactWidth = compactWidth
    self.expandedMinWidth = expandedMinWidth
    self.expandedMaxWidth = expandedMaxWidth
    self.lowPriorityIdentifiers = lowPriorityIdentifiers
  }

  /// Begin observing `window`'s toolbar. Idempotent — calling again
  /// detaches the previous observer first.
  func attach(to window: NSWindow?) {
    detach()
    self.window = window
    guard let window else { return }
    // `[.initial, .new]` so we synchronously bind whatever toolbar
    // is currently set on the window (if any), without an attach-
    // time race against SwiftUI's toolbar setup.
    toolbarObservation = window.observe(
      \.toolbar, options: [.initial, .new]
    ) { [weak self] win, _ in
      // KVO on AppKit-managed properties fires on the main thread;
      // assume main isolation synchronously rather than hopping
      // through `Task { @MainActor in ... }`, so any code that
      // reads `surfacing.*` right after the change sees fresh state
      // on the same call stack.
      MainActor.assumeIsolated {
        self?.bind(toolbar: win.toolbar)
      }
    }
  }

  /// Auto Layout width constraints we own on the toolbar item's
  /// hosted view, tagged by identifier so we can find and remove
  /// them on each apply pass without affecting other constraints.
  private static let constraintTag = "ToolbarSurfacing.width"

  private func applySize(to item: NSToolbarItem) {
    guard let view = item.view else { return }

    // Drop any width constraints we previously installed; we'll
    // recreate the right ones below for the current state.
    let stale = view.constraints.filter {
      $0.identifier == Self.constraintTag
    }
    for constraint in stale { view.removeConstraint(constraint) }

    if isExpanded {
      if expandedMinWidth > 0 {
        let constraint = view.widthAnchor.constraint(
          greaterThanOrEqualToConstant: expandedMinWidth)
        constraint.identifier = Self.constraintTag
        constraint.priority = .required
        constraint.isActive = true
      }
      if expandedMaxWidth > 0 {
        let constraint = view.widthAnchor.constraint(
          lessThanOrEqualToConstant: expandedMaxWidth)
        constraint.identifier = Self.constraintTag
        constraint.priority = .required
        constraint.isActive = true
        // Low-priority preferred-max hint so Auto Layout grows the
        // cell toward `expandedMaxWidth` when there's room.
        let prefer = view.widthAnchor.constraint(
          equalToConstant: expandedMaxWidth)
        prefer.identifier = Self.constraintTag
        prefer.priority = .defaultLow
        prefer.isActive = true
      }
    } else if compactWidth > 0 {
      let constraint = view.widthAnchor.constraint(
        equalToConstant: compactWidth)
      constraint.identifier = Self.constraintTag
      constraint.priority = .required
      constraint.isActive = true
    }

    // Tell AppKit our intrinsic measurement may have changed so
    // `NSToolbar` re-evaluates the cell size against the new
    // constraints. Without this, swapping the constraint set alone
    // doesn't always wake `NSToolbar`'s reflow.
    view.invalidateIntrinsicContentSize()
    view.superview?.invalidateIntrinsicContentSize()
  }

  /// True iff the toolbar is *actually* hosting the expanded item
  /// right now — both the host view requested expansion and
  /// `NSToolbar` kept it in `visibleItems`. The `FindBar` mount
  /// condition is the inverse: any case where the toolbar isn't
  /// the live find UI (overflow, customized out, prediction said
  /// no, surrendered after expansion attempt) should fall back to
  /// `FindBar`.
  var isToolbarActive: Bool { isExpanded && isItemSurfaced }

  /// Re-run the observation pass right now. Useful for callers that
  /// know they just did something that may have invalidated the
  /// state (e.g., a SwiftUI view transition that changes a toolbar
  /// item's intrinsic size) — re-applies `visibilityPriority` and
  /// re-reads `isVisible` / `containsItem` without waiting for the
  /// next KVO or notification.
  func refreshNow() {
    refresh(toolbar: window?.toolbar)
  }

  /// Stop observing. Safe to call multiple times.
  func detach() {
    toolbarObservation?.invalidate()
    toolbarObservation = nil
    unbindToolbar()
    window = nil
    if isVisible { isVisible = false }
    if containsItem { containsItem = false }
  }

  private func bind(toolbar: NSToolbar?) {
    unbindToolbar()
    guard let toolbar, let window else {
      if isVisible { isVisible = false }
      if containsItem { containsItem = false }
      return
    }

    refresh(toolbar: toolbar)

    visibilityObservation = toolbar.observe(
      \.isVisible, options: [.new]
    ) { [weak self] _, _ in
      self?.doRefreshNow()
    }

    // The key observation for the close-then-reopen overflow bug:
    // `NSToolbar` doesn't fire `willAddItem` / `didRemoveItem` when
    // it moves an existing item between `items` and overflow during
    // a layout-only reflow. `visibleItems` IS the property that
    // changes — and it's KVO-compliant. Observing it makes
    // `containsItem` flip in time for the host view's
    // `.onChange(of: isItemSurfaced)` to react.
    visibleItemsObservation = toolbar.observe(
      \.visibleItems, options: [.new]
    ) { [weak self] _, _ in
      self?.doRefreshNow()
    }

    let center = NotificationCenter.default
    // `willAddItemNotification` fires *before* the item enters
    // `toolbar.items` / `visibleItems`, so a synchronous refresh
    // here can't see it yet. Defer one runloop tick so we read the
    // post-add state. (Everything else stays synchronous — this is
    // the one callsite where AppKit's notification semantics force
    // it.)
    let willAdd = center.addObserver(
      forName: NSToolbar.willAddItemNotification,
      object: toolbar, queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.async { self?.doRefreshNow() }
    }
    let didRemove = center.addObserver(
      forName: NSToolbar.didRemoveItemNotification,
      object: toolbar, queue: .main
    ) { [weak self] _ in
      self?.doRefreshNow()
    }
    // Window resizes can push the item into / pull it out of the
    // overflow menu without any change to the toolbar items array.
    let didResize = center.addObserver(
      forName: NSWindow.didResizeNotification,
      object: window, queue: .main
    ) { [weak self] _ in
      self?.doRefreshNow()
    }
    notificationTokens = [willAdd, didRemove, didResize]
  }

  private func unbindToolbar() {
    visibilityObservation?.invalidate()
    visibilityObservation = nil
    visibleItemsObservation?.invalidate()
    visibleItemsObservation = nil
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    notificationTokens.removeAll()
  }

  nonisolated private func doRefreshNow() {
    // All call sites (KVO on AppKit-managed properties +
    // notifications posted with `queue: .main`) are already on the
    // main thread. Asserting isolation synchronously avoids the
    // dispatch lag that would otherwise let `.onChange` handlers
    // observe stale `isItemSurfaced` between the KVO fire and the
    // hop's resumption.
    MainActor.assumeIsolated {
      refreshNow()
    }
  }

  private func refresh(toolbar: NSToolbar?) {
    guard let toolbar else { return }
    // Bump visibility priority so other items overflow first, and
    // apply size constraints matching the current `isExpanded`
    // state. Lower priority on known sibling identifiers so the
    // differential is large enough that `NSToolbar` consistently
    // picks them to overflow instead of us — without this, the
    // close-then-reopen case can pick our item to overflow even
    // when there's room to put the others there. Done on every
    // refresh because SwiftUI's bridging may rebuild the
    // `NSToolbarItem` instance after a content change; the new
    // instance starts at default values and we re-pin.
    for item in toolbar.items {
      let id = item.itemIdentifier.rawValue
      if id == itemIdentifier {
        if item.visibilityPriority != .user {
          item.visibilityPriority = .user
        }
        applySize(to: item)
      }
    }

    let visible = toolbar.isVisible
    // `visibleItems` excludes anything currently in the overflow
    // menu. That's the right signal for "is this surface usable
    // right now" — an item rendered into the overflow popover can't
    // host a working text field.
    let contains = (toolbar.visibleItems ?? []).contains {
      $0.itemIdentifier.rawValue == itemIdentifier
    }
    if visible != isVisible { isVisible = visible }
    if contains != containsItem { containsItem = contains }
  }
}
