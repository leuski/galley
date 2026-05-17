import AppKit
import ObjectiveC.runtime

/// Replaces the AppKit tab bar "+" button (and Window > New Tab)
/// behavior on a SwiftUI `WindowGroup<URL>` window. Without this,
/// the "+" sends `newWindowForTab:` to a `WindowGroup<URL>` that
/// has no `defaultValue:`, and SwiftUI's broken default tears down
/// the current window instead of spawning a new tab — the user's
/// window appears to disappear.
///
/// We use the hook to run an Open panel and route the picks as new
/// tabs onto the source window — the canonical macOS pattern that
/// Safari and Preview implement. The rest of the tab system
/// (programmatic merge via `addTabbedWindow`, user-driven Merge
/// All Windows, tab switching, drag-out-to-detach) keeps working
/// because we only override one selector.
///
/// Why method replacement rather than `object_setClass` to a
/// runtime subclass? `object_setClass` breaks `WKWebView`'s
/// KVO observation of the host window — `WKWindowVisibilityObserver`
/// crashes inside `_NSKeyValueRetainedObservationInfoForObject`
/// during `viewWillMoveToWindow:`. Method replacement keeps the
/// dynamic class identical and only swaps the IMP for one selector.
///
/// We track which classes have already been patched so the install
/// is idempotent across many windows / many launches in the same
/// process.
enum NewTabAction {
  /// Closure invoked when a patched window receives
  /// `newWindowForTab:`. The argument is the window the click came
  /// from, so the caller can route picks as tabs onto it.
  ///
  /// Set once at startup. Read on the main thread only.
  nonisolated(unsafe) static var handler: (@MainActor (NSWindow) -> Void)?

  /// Replace `newWindowForTab:` on `window`'s class AND on its
  /// window controller's class so the action gets intercepted no
  /// matter where it lands in the responder chain. On macOS 26 +
  /// SwiftUI, the action actually lands on
  /// `SwiftUI.AppKitWindowController` before reaching the window —
  /// patching the controller is the one that matters; the window-
  /// class patch is a defensive fallback. Idempotent: each
  /// distinct class is patched once per process.
  @MainActor
  static func install(on window: NSWindow) {
    let windowClass: AnyClass =
      object_getClass(window) ?? type(of: window)
    patch(class: windowClass)

    if let controller = window.windowController {
      let controllerClass: AnyClass =
        object_getClass(controller) ?? type(of: controller)
      patch(class: controllerClass)
    }
  }

  // MARK: - Private

  /// Add `newWindowForTab:` to `cls` directly. We use
  /// `class_addMethod` rather than `class_getInstanceMethod` +
  /// `method_setImplementation` because the latter mutates the
  /// inherited Method object when `cls` doesn't override the
  /// selector — corrupting the IMP on a parent class (often
  /// NSWindow itself) for every instance in the process.
  ///
  /// `class_addMethod` is scoped to `cls` only. If `cls` already
  /// has its own override (return value false), we replace the IMP
  /// on *that* override — guaranteed to be local to `cls`.
  private static func patch(class cls: AnyClass) {
    let key = NSStringFromClass(cls)
    lock.lock()
    defer { lock.unlock() }
    if patchedClasses.contains(key) { return }
    patchedClasses.insert(key)

    let selector = NSSelectorFromString("newWindowForTab:")
    let block: @convention(block) (AnyObject, Any?) -> Void = { _, _ in
      MainActor.assumeIsolated {
        guard let key = NSApp.keyWindow else { return }
        NewTabAction.handler?(key)
      }
    }
    let imp = imp_implementationWithBlock(block)
    if !class_addMethod(cls, selector, imp, "v@:@"),
       let method = class_getInstanceMethod(cls, selector)
    {
      method_setImplementation(method, imp)
    }
  }

  private nonisolated(unsafe) static var patchedClasses = Set<String>()
  private static let lock = NSLock()
}
