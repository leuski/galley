import AppKit
import SwiftUI

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

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
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
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    // Keep the coordinator's view of the parent fresh so its
    // delegate callbacks always write through to the current
    // bindings.
    context.coordinator.parent = self

    if field.stringValue != text {
      field.stringValue = text
    }

    if isFocused {
      // Defer to the next runloop tick so we don't manipulate the
      // responder chain inside SwiftUI's render pass.
      DispatchQueue.main.async {
        guard let window = field.window else { return }
        if window.firstResponder !== field.currentEditor() {
          window.makeFirstResponder(field)
        }
      }
    } else if let window = field.window,
              window.firstResponder === field.currentEditor() {
      DispatchQueue.main.async {
        // Only resign if we still hold focus when the tick fires —
        // the user may have clicked into the field between the
        // render and the dispatch.
        guard window.firstResponder === field.currentEditor()
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
