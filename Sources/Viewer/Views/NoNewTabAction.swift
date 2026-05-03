import AppKit
import ObjectiveC.runtime

/// Neutralizes the AppKit tab bar's "+" / "New Tab" button on a
/// SwiftUI `WindowGroup<URL>` window without removing the tab bar
/// itself.
///
/// Background: clicking the "+" button on a macOS window tab bar
/// invokes `-[NSWindow newWindowForTab:]` on the key window. The
/// default implementation, when SwiftUI's `WindowGroup<URL>` is the
/// scene type and there's no `defaultValue:` provided, tears down
/// the current window without successfully spawning a replacement
/// — the user's window appears to disappear. There is no public
/// API to "hide the + button only" without disabling tabs entirely
/// via `NSWindow.tabbingMode = .disallowed`, but we want the rest
/// of the tab system (programmatic merge via `addTabbedWindow`,
/// user-driven Merge All Windows, tab switching, drag-out-to-detach)
/// to keep working.
///
/// Approach: method replacement on the live window's class.
/// SwiftUI's WindowGroup<URL> spawns instances of an internal
/// `NSWindow` subclass; the first time we see one, we replace its
/// `newWindowForTab:` implementation with a no-op block. Every
/// subsequent window of the same class inherits the no-op for free.
///
/// Why method replacement rather than `object_setClass` to a
/// runtime subclass? `object_setClass` breaks `WKWebView`'s
/// KVO observation of the host window — `WKWindowVisibilityObserver`
/// crashes inside `_NSKeyValueRetainedObservationInfoForObject`
/// during `viewWillMoveToWindow:`. Method replacement keeps the
/// dynamic class identical, only swapping the IMP for one selector.
///
/// We track which classes have already been patched so the
/// install is idempotent across many windows / many launches in
/// the same process.
enum NoNewTabAction {
  static func install(on window: NSWindow) {
    let cls: AnyClass = object_getClass(window) ?? type(of: window)
    let key = NSStringFromClass(cls)
    lock.lock()
    defer { lock.unlock() }
    if patchedClasses.contains(key) { return }
    patchedClasses.insert(key)

    let selector = NSSelectorFromString("newWindowForTab:")
    let block: @convention(block) (Any, Any?) -> Void = { _, _ in
      // Deliberate no-op. The "+" click reaches us via the
      // standard target/action dispatch on the key window's
      // class. Swallowing it here prevents SwiftUI's broken
      // default behavior from running.
    }
    let imp = imp_implementationWithBlock(block)
    if let method = class_getInstanceMethod(cls, selector) {
      method_setImplementation(method, imp)
    } else {
      // Type encoding: void return, two object args (self, sender).
      class_addMethod(cls, selector, imp, "v@:@")
    }
  }

  // MARK: - Private

  private nonisolated(unsafe) static var patchedClasses = Set<String>()
  private static let lock = NSLock()
}
