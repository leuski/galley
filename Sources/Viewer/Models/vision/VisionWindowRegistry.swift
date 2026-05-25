#if os(visionOS)
import SwiftUI

/// Single source of truth for which windows of the document
/// `WindowGroup` are currently alive. Drives two UX rules:
///
/// - When the last window closes **and it was holding a document**,
///   spawn a fresh empty (welcome) window so the app stays alive on
///   a landing surface. If the last window closed was already empty
///   the user has intentionally closed everything — let the OS
///   suspend the app.
/// - When a document arrives from the Mac via Kosmos, every live
///   welcome window should step aside in favor of the freshly-opened
///   doc window. We can't target the nil-URL instance from outside
///   — `dismissWindow(id:value:)` keys on the *presented* type (URL,
///   not URL?), so the empty is externally unaddressable. Instead,
///   `requestDismissEmpties` bumps `dismissEmptiesToken` and every
///   welcome surface observes the change to call `dismissWindow()`
///   on itself.
///
/// Each window registers its `Binding<URL?>` at `register` time and
/// removes it at `unregister`. We don't track "empty" vs. "doc" as a
/// separate count: the binding's `wrappedValue` is the truth — empty
/// when `nil`, document when not — and we read it at the moment a
/// window unregisters to decide whether the disappearance should
/// trigger `onNeedEmpty`.
@MainActor
@Observable
final class VisionWindowRegistry {
  private struct WindowMetadata {
    var binding: Binding<URL?>
    let dismiss: DismissWindowAction
  }

  /// Live windows keyed by a per-window stable UUID assigned in
  /// `@State` on first mount. Holding the SwiftUI `Binding<URL?>`
  /// lets us inspect each window's current URL slot without having
  /// to mirror it into the registry on every change.
  @ObservationIgnored
  private var windows: [UUID: WindowMetadata] = [:]

  var openWindow: OpenWindowAction?

  func register(
    id: UUID, binding: Binding<URL?>, dismiss: DismissWindowAction)
  {
    windows[id] = WindowMetadata(binding: binding, dismiss: dismiss)
  }

  func openURL(_ url: URL) {
    for window in windows.values where window.binding.wrappedValue == nil {
      window.binding.wrappedValue = url
      return
    }
    openWindow?(id: VisionViewerApp.main, value: url)
  }

  func unregister(id: UUID) {
    guard let leaving = windows.removeValue(forKey: id) else { return }
    // Spawn an empty only when the last live window held a document.
    // If the last window was already empty, the user closed
    // everything → suspend. If the app is backgrounding, every
    // remaining per-scene `.background` walks through here; we don't
    // want to chase the OS by trying to open windows on the way out.
    if windows.isEmpty, leaving.binding.wrappedValue != nil {
      // we must force-dismiss the last window, otherwise it leaks
      // memory and jams the kosmos tunnel if any.
      leaving.dismiss()
      openWindow?(id: VisionViewerApp.main)
    }
  }
}
#endif
