import AppKit
import SwiftUI

/// `NSTextField` subclass that detects "removed from its window
/// *after* this instance held first responder." Defensive safety
/// net for a previously-observed AppKit bug where `NSToolbar`'s
/// relayout on the second expand would swap `NSToolbarItem.view`
/// out from under SwiftUI's hosting, taking our focused field with
/// it. Eliminated by always-mounting both states in
/// `ToolbarSearchField`'s `ZStack`, but the recovery path is cheap
/// to keep in case the underlying AppKit behavior resurfaces.
///
/// `markBecameFirstResponder()` is called from
/// `AppKitSearchField.updateNSView` when `makeFirstResponder`
/// succeeds, so phantom instances that are torn down before focus
/// lands don't trip the recovery.
final class WindowAwareTextField: NSTextField {
  var onLostWindowAfterFocus: (() -> Void)?
  private var everHadFocus = false

  func markBecameFirstResponder() {
    everHadFocus = true
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, self.window != nil, everHadFocus {
      // Defer the callback — we're inside an AppKit view-hierarchy
      // mutation, and the callback writes SwiftUI state that can
      // re-enter the toolbar layout.
      let callback = onLostWindowAfterFocus
      DispatchQueue.main.async { callback?() }
    }
    super.viewWillMove(toWindow: newWindow)
  }
}

/// `NSTextField`-backed search input. SwiftUI's `TextField` +
/// `@FocusState` does not reliably grant or report focus when hosted
/// inside a toolbar item — focus dispatch races the SwiftUI host
/// view's mount and the `@FocusState` binding does not always see
/// AppKit-level focus loss. This wrapper sidesteps that by managing
/// first-responder state directly through the responder chain and
/// reporting changes through `NSTextFieldDelegate`.
///
/// Two-way `isFocused` binding:
///
/// - The owner can request focus by writing `true` — the next
///   `updateNSView` pass calls `window.makeFirstResponder(field)`.
/// - The wrapper writes `true`/`false` back from
///   `controlTextDidBeginEditing` / `controlTextDidEndEditing` so
///   the owner can react to the user clicking elsewhere.
struct AppKitSearchField: NSViewRepresentable {
  @Binding var text: String
  let prompt: String
  @Binding var isFocused: Bool
  let onSubmit: () -> Void
  let onCancel: () -> Void
  /// Fired when the field's hosted `NSView` is removed from its
  /// window *after* it had first-responder focus. Defaults to no-op
  /// so non-toolbar callers (e.g. `FindBar`) don't need to wire
  /// anything.
  var onLostWindow: () -> Void = {}

  func makeNSView(context: Context) -> NSTextField {
    let field = WindowAwareTextField()
    field.onLostWindowAfterFocus = onLostWindow
    field.placeholderString = prompt
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.lineBreakMode = .byTruncatingTail
    field.cell?.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.commit(_:))
    // Let SwiftUI's enclosing `.frame(maxWidth:)` stretch the field
    // horizontally. NSTextField's default hugging / compression-
    // resistance priorities keep it at its intrinsic content width
    // otherwise.
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(
      .defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    // Keep the coordinator's view of the parent fresh and refresh
    // the lost-window callback so the latest closure (capturing
    // the current `ToolbarSearchField` state) runs.
    context.coordinator.parent = self
    if let aware = field as? WindowAwareTextField {
      aware.onLostWindowAfterFocus = onLostWindow
    }

    if field.stringValue != text {
      field.stringValue = text
    }

    if isFocused {
      // Defer to the next runloop tick so we don't manipulate the
      // responder chain inside SwiftUI's render pass.
      DispatchQueue.main.async {
        guard let window = field.window else { return }
        if window.firstResponder !== field.currentEditor() {
          let ok = window.makeFirstResponder(field)
          if ok, let aware = field as? WindowAwareTextField {
            aware.markBecameFirstResponder()
          }
        }
      }
    } else if let window = field.window,
              window.firstResponder === field.currentEditor() {
      // The field is always mounted (`ToolbarSearchField`'s ZStack
      // keeps it alive across opens), so when `isFocused` goes
      // false we have to actively release first responder —
      // otherwise the invisible field keeps editing focus and
      // keyboard input still goes to it.
      DispatchQueue.main.async {
        guard let window = field.window,
              window.firstResponder === field.currentEditor()
        else { return }
        window.makeFirstResponder(nil)
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AppKitSearchField

    init(parent: AppKitSearchField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField
      else { return }
      parent.text = field.stringValue
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      if !parent.isFocused { parent.isFocused = true }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      if parent.isFocused { parent.isFocused = false }
    }

    @objc func commit(_ sender: Any) {
      parent.onSubmit()
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        parent.onCancel()
        return true
      }
      return false
    }
  }
}
