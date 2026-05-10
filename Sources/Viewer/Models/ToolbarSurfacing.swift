import AppKit
import Observation

/// Tracks whether a specific toolbar item is currently surfaced in
/// the host window's `NSToolbar`. "Surfaced" means the toolbar is
/// visible *and* the item identifier is present in the toolbar's
/// active item list (i.e., not removed via Customize Toolbar).
///
/// Used by `DocumentView` to decide whether the toolbar's
/// `ToolbarSearchField` is the live find UI or whether the
/// `safeAreaInset` `FindBar` should appear instead.
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
@MainActor
@Observable
final class ToolbarSurfacing {
  let itemIdentifier: String

  /// Toolbar's `isVisible` — flips with View > Show/Hide Toolbar
  /// (⌥⌘T). Independent of customization.
  private(set) var isVisible: Bool = false

  /// Whether `itemIdentifier` is in the toolbar's active item list.
  /// False when the user has dragged the item out via Customize
  /// Toolbar.
  private(set) var containsItem: Bool = false

  var isItemSurfaced: Bool { isVisible && containsItem }

  @ObservationIgnored
  private weak var window: NSWindow?
  @ObservationIgnored
  private var toolbarObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var visibilityObservation: NSKeyValueObservation?
  @ObservationIgnored
  private var notificationTokens: [NSObjectProtocol] = []

  init(itemIdentifier: String) {
    self.itemIdentifier = itemIdentifier
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
      Task { @MainActor [weak self] in
        let toolbar = win.toolbar
        self?.bind(toolbar: toolbar)
      }
    }
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
    guard let toolbar else {
      if isVisible { isVisible = false }
      if containsItem { containsItem = false }
      return
    }

    refresh(toolbar: toolbar)

    visibilityObservation = toolbar.observe(
      \.isVisible, options: [.new]
    ) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self, let toolbar = self.window?.toolbar
        else { return }
        self.refresh(toolbar: toolbar)
      }
    }

    let center = NotificationCenter.default
    let willAdd = center.addObserver(
      forName: NSToolbar.willAddItemNotification,
      object: toolbar, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let toolbar = self.window?.toolbar
        else { return }
        self.refresh(toolbar: toolbar)
      }
    }
    let didRemove = center.addObserver(
      forName: NSToolbar.didRemoveItemNotification,
      object: toolbar, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let toolbar = self.window?.toolbar
        else { return }
        self.refresh(toolbar: toolbar)
      }
    }
    notificationTokens = [willAdd, didRemove]
  }

  private func unbindToolbar() {
    visibilityObservation?.invalidate()
    visibilityObservation = nil
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    notificationTokens.removeAll()
  }

  private func refresh(toolbar: NSToolbar) {
    let visible = toolbar.isVisible
    let contains = toolbar.items.contains {
      $0.itemIdentifier.rawValue == itemIdentifier
    }
    if visible != isVisible { isVisible = visible }
    if contains != containsItem { containsItem = contains }
  }
}
